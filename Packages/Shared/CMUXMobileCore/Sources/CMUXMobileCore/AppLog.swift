public import Foundation

/// The consolidated on-disk application log: one active file with bounded
/// archives for app-wide events and one equivalent set for network diagnostics.
///
/// ``AppLog`` is the durable half of the diagnostics stack. The in-memory
/// ``DiagnosticLog`` ring stays the single structured spine every subsystem
/// records into; the composition root taps that ring into an ``AppLog``, which
/// renders each event through ``DiagnosticEventPresentation`` and appends it to
/// one of two files:
///
/// - the **app log** (``appLogFileName``): every event that is not
///   network-plane — simulator streaming/control, browser streaming, composer,
///   render — plus mirrored string debug-log lines, so one file tells the whole
///   in-app story in wall-clock order;
/// - the **network log** (``networkLogFileName``): transport dials, discovery,
///   relay policy, path changes, session lifecycle and close attribution.
///
/// Cross-cutting context (app lifecycle, reachability) is written to both so
/// each file is self-sufficient. Diagnostic events are integer-encoded and
/// privacy-safe by construction, so persistence is always on, including
/// Release; the free-text mirror keeps the string log's own gating (DEBUG
/// always, Release behind the verbose opt-in) because those lines are not
/// structurally scrubbed.
///
/// Ordering: both entry points are non-blocking and feed one buffered stream
/// drained by a single internal task, so lines land on disk in admission
/// order. Consecutive frame-pipeline events for the same panel and stage are
/// coalesced into a `repeated ×N` summary when the run breaks, so a healthy
/// 20 fps stream costs one line plus one summary instead of megabytes.
///
/// The active generation is reopened for appending on the next launch. When
/// the byte budget is reached it is moved to a timestamped archive, then a
/// fresh active generation is opened. Archives are bounded by both count and
/// total bytes, so retention never requires clearing the app container.
///
/// Inject one instance from the app composition root; do not add a `.shared`
/// singleton.
public actor AppLog {
    /// Which on-disk file an event belongs to.
    public enum Domain: Sendable, Equatable {
        case app
        case network
        case both
    }

    public static let appLogFileName = "cmux-app.log"
    public static let networkLogFileName = "cmux-network.log"
    /// The ZIP member names used by the single diagnostics export. The
    /// directory prefix makes the archive open as a folder in Files while
    /// keeping the archive to exactly two file members.
    public static let exportDirectoryName = "cmux-diagnostics"
    public static let exportAppFileName = "app-events.log"
    public static let exportNetworkFileName = "networking.log"
    /// The approximate size of one active generation in production.
    public static let defaultMaxFileBytes = 5_000_000
    /// Number of timestamped generations retained in addition to the active
    /// file. A legacy `.1` file is migrated before this limit is applied.
    public static let defaultMaxArchiveCount = 3
    /// Per-file retention ceiling, including the active generation.
    public static let defaultMaxRetainedBytes = 12_000_000

    /// Default location of the app-wide log inside Application Support, or
    /// `nil` when the directory cannot be resolved. Exists so settings UI can
    /// offer the file for sharing without holding the ``AppLog`` instance.
    public static var defaultAppLogFileURL: URL? {
        defaultFileURL(named: appLogFileName)
    }

    /// Default location of the network diagnostics log. See
    /// ``defaultAppLogFileURL``.
    public static var defaultNetworkLogFileURL: URL? {
        defaultFileURL(named: networkLogFileName)
    }

    /// All available generations for the app log, with the active file first.
    /// Retained for callers that need to inspect raw generations; user-facing
    /// exports should use ``exportLogs()``.
    public static var appLogFileURLs: [URL] {
        guard let url = defaultAppLogFileURL else { return [] }
        return logFileURLs(for: url)
    }

    /// All available generations for the network log, with the active file
    /// first. See ``appLogFileURLs``. User-facing exports should use
    /// ``exportLogs()`` so rotation history is merged into one member.
    public static var networkLogFileURLs: [URL] {
        guard let url = defaultNetworkLogFileURL else { return [] }
        return logFileURLs(for: url)
    }

    /// Returns the active file and any retained archive generations for a
    /// caller-supplied location. The legacy `<name>.1` generation is included
    /// when a prior build could not migrate it.
    public static func logFileURLs(for fileURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        if fileManager.fileExists(atPath: fileURL.path) {
            urls.append(fileURL)
        }
        urls.append(contentsOf: archiveURLs(for: fileURL))
        let legacyURL = legacyRotationURL(for: fileURL)
        if fileManager.fileExists(atPath: legacyURL.path) {
            urls.append(legacyURL)
        }
        return urls
    }

    private static let archiveMarker = ".archive-"

    private static func legacyRotationURL(for fileURL: URL) -> URL {
        URL(fileURLWithPath: fileURL.path + ".1")
    }

    private static func archivePrefix(for fileURL: URL) -> String {
        let stem = fileURL.pathExtension.isEmpty
            ? fileURL.lastPathComponent
            : fileURL.deletingPathExtension().lastPathComponent
        return "\(stem)\(archiveMarker)"
    }

    private static func archiveStamp(for url: URL, prefix: String) -> Int64? {
        let remainder = url.lastPathComponent.dropFirst(prefix.count)
        let stamp = remainder.prefix(13)
        guard stamp.count == 13,
              stamp.allSatisfy({ $0.isNumber }),
              remainder.dropFirst(stamp.count).first == "-"
        else {
            return nil
        }
        return Int64(stamp)
    }

    private static func archiveURLs(for fileURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let prefix = archivePrefix(for: fileURL)
        guard let names = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return names
            .filter { candidate in
                candidate.lastPathComponent.hasPrefix(prefix)
                    && candidate.pathExtension == fileURL.pathExtension
                    && fileManager.fileExists(atPath: candidate.path)
            }
            .sorted { lhs, rhs in
                let leftStamp = archiveStamp(for: lhs, prefix: prefix)
                let rightStamp = archiveStamp(for: rhs, prefix: prefix)
                switch (leftStamp, rightStamp) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let leftDate = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    private static func makeArchiveURL(for fileURL: URL, date: Date) -> URL {
        let stem = fileURL.pathExtension.isEmpty
            ? fileURL.lastPathComponent
            : fileURL.deletingPathExtension().lastPathComponent
        let extensionSuffix = fileURL.pathExtension.isEmpty
            ? ""
            : ".\(fileURL.pathExtension)"
        let milliseconds = Int64(date.timeIntervalSince1970 * 1_000)
        let stamp = String(format: "%013lld", milliseconds)
        let unique = String(UUID().uuidString.prefix(8))
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(stem)\(archiveMarker)\(stamp)-\(unique)\(extensionSuffix)"
            )
    }

    private static func defaultFileURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return base.appendingPathComponent(name)
    }

    private enum Entry: Sendable {
        case event(DiagnosticEvent, wall: Date)
        case appLine(String, wall: Date)
        case barrier(Acknowledgement)
        case clear(Acknowledgement)
    }

    /// A one-shot acknowledgement that can be resolved by either the drain or
    /// the export task's timeout/cancellation path without ever resuming a
    /// continuation twice.
    private final class Acknowledgement: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait(timeoutNanoseconds: UInt64) async -> Bool {
            let timeoutTask = Task.detached { [self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    resolve(false)
                } catch {
                    // The waiter completed before the deadline.
                }
            }
            let result = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if let resolvedResult = self.result {
                        lock.unlock()
                        continuation.resume(returning: resolvedResult)
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            }, onCancel: {
                resolve(false)
            })
            timeoutTask.cancel()
            return result
        }

        func signal(_ result: Bool = true) {
            resolve(result)
        }

        private func resolve(_ result: Bool) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    /// Synchronously admits entries from arbitrary producer threads while
    /// keeping normal event and mirrored-line traffic bounded. Control entries
    /// are never evicted; when the traffic budget is full, the oldest droppable
    /// entry is discarded.
    // lint:allow lock - synchronous admission is required for nonisolated
    // producers; the lock is held only while updating a bounded in-memory queue.
    private final class EntryIngress: @unchecked Sendable {
        private struct State: Sendable {
            var entries: [Entry] = []
            var bufferedDroppableCount = 0
            var finished = false
        }

        private let lock = NSLock()
        private var state = State()
        private let maxBufferedEntries: Int
        private let wakeContinuation: AsyncStream<Void>.Continuation
        private var wakeIterator: AsyncStream<Void>.Iterator

        init(maxBufferedEntries: Int = 2_048) {
            self.maxBufferedEntries = max(1, maxBufferedEntries)
            let (stream, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            wakeContinuation = continuation
            wakeIterator = stream.makeAsyncIterator()
        }

        func enqueue(_ entry: Entry) {
            let admitted = withStateLock { state in
                guard !state.finished else { return false }
                if Self.isDroppable(entry) {
                    if state.bufferedDroppableCount >= maxBufferedEntries,
                       let oldestDroppable = state.entries.firstIndex(where: Self.isDroppable) {
                        state.entries.remove(at: oldestDroppable)
                        state.bufferedDroppableCount -= 1
                    }
                    state.bufferedDroppableCount += 1
                }
                state.entries.append(entry)
                return true
            }
            if admitted {
                wakeContinuation.yield(())
            } else {
                Self.resumeControl(entry)
            }
        }

        func nextBatch() async -> [Entry]? {
            while true {
                if let batch = withStateLock({ state -> [Entry]? in
                    guard !state.entries.isEmpty else {
                        return state.finished ? nil : []
                    }
                    let batch = state.entries
                    state.entries.removeAll(keepingCapacity: true)
                    state.bufferedDroppableCount = 0
                    return batch
                }) {
                    if !batch.isEmpty { return batch }
                } else {
                    return nil
                }

                guard await wakeIterator.next() != nil else {
                    if let batch = withStateLock({ state -> [Entry]? in
                        guard !state.entries.isEmpty else { return nil }
                        let batch = state.entries
                        state.entries.removeAll(keepingCapacity: true)
                        state.bufferedDroppableCount = 0
                        return batch
                    }) {
                        return batch
                    }
                    return nil
                }
            }
        }

        func finish() {
            let pending = withStateLock { state -> [Entry] in
                state.finished = true
                let pending = state.entries
                state.entries.removeAll(keepingCapacity: false)
                state.bufferedDroppableCount = 0
                return pending
            }
            for entry in pending {
                Self.resumeControl(entry)
            }
            wakeContinuation.finish()
        }

        private func withStateLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }

        private static func isDroppable(_ entry: Entry) -> Bool {
            switch entry {
            case .event, .appLine:
                return true
            case .barrier, .clear:
                return false
            }
        }

        private static func resumeControl(_ entry: Entry) {
            switch entry {
            case .barrier(let acknowledgement), .clear(let acknowledgement):
                acknowledgement.signal()
            case .event, .appLine:
                break
            }
        }
    }

    private struct LogFile {
        let url: URL
        let maxBytes: Int
        let maxArchiveCount: Int
        let maxRetainedBytes: Int
        let header: String
        let now: @Sendable () -> Date
        var handle: FileHandle?
        var bytesWritten = 0
        /// Byte level at which the next rotation is attempted. Normally
        /// `maxBytes`; raised after a failed rotate so a sustained failure
        /// (busy file, read-only directory) retries once per additional
        /// budget of growth instead of once per appended line.
        var rotationThreshold: Int

        init(
            url: URL,
            maxBytes: Int,
            maxArchiveCount: Int,
            maxRetainedBytes: Int,
            header: String,
            now: @escaping @Sendable () -> Date
        ) {
            self.url = url
            self.maxBytes = max(1, maxBytes)
            self.maxArchiveCount = max(1, maxArchiveCount)
            self.maxRetainedBytes = max(maxRetainedBytes, self.maxBytes)
            self.header = header
            self.now = now
            self.rotationThreshold = max(1, maxBytes)
            migrateLegacyRotation()
            if FileManager.default.fileExists(atPath: url.path) {
                openExistingForAppending()
                if handle != nil, bytesWritten >= self.maxBytes {
                    _ = rotate()
                }
            } else {
                _ = openFreshGeneration()
            }
            if handle != nil {
                pruneArchives()
            }
        }

        /// Moves a legacy `<name>.1` generation into the timestamped archive
        /// namespace. If the move cannot be completed, the legacy file stays
        /// untouched and remains shareable.
        private mutating func migrateLegacyRotation() {
            let fileManager = FileManager.default
            let legacyURL = AppLog.legacyRotationURL(for: url)
            guard fileManager.fileExists(atPath: legacyURL.path) else { return }
            let archiveURL = AppLog.makeArchiveURL(for: url, date: now())
            try? fileManager.moveItem(at: legacyURL, to: archiveURL)
        }

        /// Opens a new active generation. This method never removes or
        /// overwrites an existing file. The caller must move an old active
        /// generation away first.
        @discardableResult
        private mutating func openFreshGeneration() -> Bool {
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: url.path),
                  fileManager.createFile(atPath: url.path, contents: nil),
                  let opened = try? FileHandle(forWritingTo: url) else {
                handle = nil
                return false
            }
            handle = opened
            bytesWritten = 0
            rotationThreshold = maxBytes
            write(header)
            return handle != nil
        }

        /// Rotates the active generation into a unique archive. A failed move
        /// reopens the original file for appending and leaves every existing
        /// byte in place. If creating the replacement fails after the move,
        /// the archive is restored when possible; otherwise it remains on disk
        /// and is still returned by ``AppLog.logFileURLs(for:)``.
        @discardableResult
        private mutating func rotate() -> Bool {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                return openFreshGeneration()
            }
            close()
            let archiveURL = AppLog.makeArchiveURL(for: url, date: now())
            do {
                try fileManager.moveItem(at: url, to: archiveURL)
            } catch {
                openExistingForAppending()
                rotationThreshold = bytesWritten + maxBytes
                return false
            }
            guard openFreshGeneration() else {
                if !fileManager.fileExists(atPath: url.path) {
                    try? fileManager.moveItem(at: archiveURL, to: url)
                }
                openExistingForAppending()
                rotationThreshold = bytesWritten + maxBytes
                return false
            }
            pruneArchives()
            return true
        }

        /// Keeps writing to the current generation. Existing files are opened
        /// at their end, never truncated. An empty pre-existing file receives
        /// the generation header once.
        private mutating func openExistingForAppending() {
            guard let opened = try? FileHandle(forWritingTo: url),
                  let size = try? opened.seekToEnd() else {
                // A generation that cannot be opened or positioned at its end
                // is not safely appendable: writing from offset 0 would
                // overwrite the content this fallback exists to preserve.
                handle = nil
                return
            }
            handle = opened
            bytesWritten = Int(clamping: size)
            rotationThreshold = maxBytes
            if bytesWritten == 0 {
                write(header)
            }
        }

        mutating func append(_ line: String) {
            guard handle != nil else { return }
            let data = Data((line + "\n").utf8)
            if bytesWritten + data.count > rotationThreshold {
                _ = rotate()
            }
            write(line)
        }

        /// Removes only timestamped archives, and only after a new active
        /// generation has been opened. The newest archive is always kept even
        /// if one unusually large line temporarily exceeds the byte ceiling.
        private mutating func pruneArchives() {
            let fileManager = FileManager.default
            var archives = AppLog.archiveURLs(for: url)
            guard !archives.isEmpty else { return }
            var totalBytes = fileSize(of: url)
            var archiveSizes = archives.map { fileSize(of: $0) }
            totalBytes += archiveSizes.reduce(0, +)
            while archives.count > maxArchiveCount || totalBytes > maxRetainedBytes {
                guard archives.count > 1 else { break }
                let oldestIndex = archives.count - 1
                let oldest = archives.remove(at: oldestIndex)
                let oldestSize = archiveSizes.remove(at: oldestIndex)
                do {
                    try fileManager.removeItem(at: oldest)
                    totalBytes -= oldestSize
                } catch {
                    // A protection or sharing failure should never cause us
                    // to remove a different, newer generation.
                    break
                }
            }
        }

        private func fileSize(of fileURL: URL) -> Int {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return 0
            }
            return size
        }

        private mutating func write(_ line: String) {
            guard let handle else { return }
            let data = Data((line + "\n").utf8)
            do {
                try handle.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                try? handle.close()
                self.handle = nil
            }
        }

        mutating func close() {
            try? handle?.close()
            handle = nil
        }

        /// Removes this file and every retained generation, then starts a new
        /// active generation with the normal header.
        @discardableResult
        mutating func clear() -> Bool {
            close()
            let fileManager = FileManager.default
            var didRemoveEverything = true
            for generation in AppLog.logFileURLs(for: url) {
                do {
                    try fileManager.removeItem(at: generation)
                } catch {
                    didRemoveEverything = false
                }
            }
            guard didRemoveEverything else {
                openExistingForAppending()
                return false
            }
            return openFreshGeneration()
        }
    }

    /// One in-progress run of coalescible frame events.
    private struct FrameRun {
        let key: FrameRunKey
        var lastEvent: DiagnosticEvent
        var count: Int
    }

    private struct FrameRunKey: Equatable {
        let code: DiagnosticEventCode
        let surface: UInt32?
        let stage: Int?
    }

    private var appFile: LogFile?
    private var networkFile: LogFile?
    private var pendingFrameRun: FrameRun?
    private var processed = 0
    private let presentation = DiagnosticEventPresentation()
    private let timestampFormatter: ISO8601DateFormatter
    private let ingress: EntryIngress
    private let supplementalAppLogURLs: @Sendable () -> [URL]
    private let flushSupplementalAppLog: @Sendable () async -> Bool

    private static let drainWaitTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Create a log writing to the given locations. Passing `nil` for a URL
    /// disables that file (used by tests exercising one file at a time).
    public init(
        appFileURL: URL?,
        networkFileURL: URL?,
        maxFileBytes: Int = AppLog.defaultMaxFileBytes,
        buildStamp: String = "",
        maxArchiveCount: Int = AppLog.defaultMaxArchiveCount,
        maxRetainedBytes: Int = AppLog.defaultMaxRetainedBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        supplementalAppLogURLs: @escaping @Sendable () -> [URL] = { [] },
        flushSupplementalAppLog: @escaping @Sendable () async -> Bool = { true }
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
        self.supplementalAppLogURLs = supplementalAppLogURLs
        self.flushSupplementalAppLog = flushSupplementalAppLog
        let started = formatter.string(from: now())
        if let appFileURL {
            appFile = LogFile(
                url: appFileURL,
                maxBytes: maxFileBytes,
                maxArchiveCount: maxArchiveCount,
                maxRetainedBytes: maxRetainedBytes,
                header: "cmux app log · \(buildStamp) · started \(started)",
                now: now
            )
        }
        if let networkFileURL {
            networkFile = LogFile(
                url: networkFileURL,
                maxBytes: maxFileBytes,
                maxArchiveCount: maxArchiveCount,
                maxRetainedBytes: maxRetainedBytes,
                header: "cmux network diagnostics log · \(buildStamp) · started \(started)",
                now: now
            )
        }
        let ingress = EntryIngress()
        self.ingress = ingress
        // The drain holds self only across one write; when the log deallocs,
        // `deinit` finishes ingress and the loop ends on its own.
        Task { [weak self] in
            while let batch = await ingress.nextBatch() {
                for entry in batch {
                    guard let self else { return }
                    await self.write(entry)
                }
            }
        }
    }

    deinit {
        ingress.finish()
    }

    /// Record one structured diagnostic event. Non-blocking and safe to call
    /// from the ``DiagnosticLog`` event tap (which runs on the ring's drain
    /// task and must not block).
    public nonisolated func ingest(_ event: DiagnosticEvent) {
        ingress.enqueue(.event(event, wall: Date()))
    }

    /// Mirror one free-text debug-log line into the app file. The caller owns
    /// the privacy gating (the string debug log only produces lines in DEBUG
    /// or behind the user's verbose opt-in).
    public nonisolated func mirrorAppLine(_ line: String) {
        ingress.enqueue(.appLine(line, wall: Date()))
    }

    /// The total number of entries the drain task has written. Never
    /// decreases, so after admitting `n` entries a test can poll this to `n`
    /// to know everything reached the files, without sleeping.
    public func processedCount() -> Int {
        processed
    }

    /// Flushes a pending coalesced frame run to disk. Test-only
    /// synchronization; in production runs flush when they break.
    public func flushForTesting() {
        flushPendingFrameRun()
    }

    private func write(_ entry: Entry) {
        processed += 1
        switch entry {
        case .event(let event, let wall):
            writeEvent(event, wall: wall)
        case .appLine(let line, let wall):
            flushPendingFrameRun()
            appFile?.append("\(timestampFormatter.string(from: wall)) \(line)")
        case .barrier(let acknowledgement):
            flushPendingFrameRun()
            acknowledgement.signal()
        case .clear(let acknowledgement):
            pendingFrameRun = nil
            let appCleared = appFile?.clear() ?? true
            let networkCleared = networkFile?.clear() ?? true
            acknowledgement.signal(appCleared && networkCleared)
        }
    }

    /// Waits until all entries admitted before the call have reached disk, then
    /// creates one shareable ZIP containing only `app-events.log` and
    /// `networking.log` under a `cmux-diagnostics/` folder.
    ///
    /// The active file and retained generations are merged into their domain's
    /// member, so rotation history never turns into extra files in the export.
    public func exportLogs() async -> URL? {
        guard await flushSupplementalAppLog() else { return nil }
        let acknowledgement = Acknowledgement()
        ingress.enqueue(.barrier(acknowledgement))
        guard await acknowledgement.wait(timeoutNanoseconds: Self.drainWaitTimeoutNanoseconds),
              !Task.isCancelled else {
            return nil
        }

        guard let appData = mergedData(
            for: appFile?.url,
            additionalURLs: supplementalAppLogURLs()
        ),
              let networkData = mergedData(for: networkFile?.url) else {
            return nil
        }
        return Self.writeZipArchive(entries: [
            ("\(Self.exportDirectoryName)/\(Self.exportAppFileName)", appData),
            ("\(Self.exportDirectoryName)/\(Self.exportNetworkFileName)", networkData),
        ])
    }

    /// Clears the structured log files, including all retained generations.
    /// Entries already admitted before this call are drained first, so a clear
    /// cannot be undone by an older write still waiting in the ingress stream.
    @discardableResult
    public func clear() async -> Bool {
        let acknowledgement = Acknowledgement()
        ingress.enqueue(.clear(acknowledgement))
        return await acknowledgement.wait(timeoutNanoseconds: Self.drainWaitTimeoutNanoseconds)
    }

    private func mergedData(for fileURL: URL?, additionalURLs: [URL] = []) -> Data? {
        guard let fileURL else { return nil }
        let generations = Array(Self.logFileURLs(for: fileURL).reversed())
        var merged = Data()
        for generation in generations {
            guard let data = try? Data(contentsOf: generation) else { return nil }
            if !merged.isEmpty, merged.last != 0x0A {
                merged.append(0x0A)
            }
            merged.append(data)
        }
        var existingLines = Set(merged.split(separator: 0x0A, omittingEmptySubsequences: true))
        for generation in additionalURLs.reversed() {
            guard let data = try? Data(contentsOf: generation) else { return nil }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let lineData = Data(line)
                guard !existingLines.contains(line), merged.range(of: lineData) == nil else {
                    continue
                }
                if !merged.isEmpty, merged.last != 0x0A {
                    merged.append(0x0A)
                }
                merged.append(contentsOf: lineData)
                merged.append(0x0A)
                existingLines.insert(line)
            }
        }
        return merged
    }

    private struct ZipEntry {
        let name: String
        let byteCount: UInt32
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    /// Writes a minimal ZIP32 archive using the store method. Logs are already
    /// bounded by AppLog's retention policy, and avoiding a second compression
    /// pass keeps export responsive on older iPhones.
    private static func writeZipArchive(
        entries: [(name: String, data: Data)]
    ) -> URL? {
        let directory = FileManager.default.temporaryDirectory
        let archiveURL = directory.appendingPathComponent(
            "cmux-diagnostics-\(UUID().uuidString).zip"
        )
        var archive = Data()
        var centralEntries: [ZipEntry] = []
        centralEntries.reserveCapacity(entries.count)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                return nil
            }
            let offset = UInt32(archive.count)
            let checksum = crc32(entry.data)
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(20, to: &archive) // version needed to extract
            appendUInt16(0x0800, to: &archive) // UTF-8 names
            appendUInt16(0, to: &archive) // stored, no compression
            appendUInt16(0, to: &archive) // DOS time
            appendUInt16(0, to: &archive) // DOS date
            appendUInt32(checksum, to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive) // extra field length
            archive.append(nameData)
            archive.append(entry.data)
            centralEntries.append(ZipEntry(
                name: entry.name,
                byteCount: UInt32(entry.data.count),
                crc32: checksum,
                localHeaderOffset: offset
            ))
        }

        guard archive.count <= Int(UInt32.max) else { return nil }
        let centralDirectoryOffset = UInt32(archive.count)
        for entry in centralEntries {
            guard let nameData = entry.name.data(using: .utf8) else { return nil }
            appendUInt32(0x0201_4b50, to: &archive)
            appendUInt16(20, to: &archive) // version made by
            appendUInt16(20, to: &archive) // version needed to extract
            appendUInt16(0x0800, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(entry.crc32, to: &archive)
            appendUInt32(entry.byteCount, to: &archive)
            appendUInt32(entry.byteCount, to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive) // extra field length
            appendUInt16(0, to: &archive) // comment length
            appendUInt16(0, to: &archive) // disk number
            appendUInt16(0, to: &archive) // internal attributes
            appendUInt32(0, to: &archive) // external attributes
            appendUInt32(entry.localHeaderOffset, to: &archive)
            archive.append(nameData)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive) // disk number
        appendUInt16(0, to: &archive) // central directory disk
        appendUInt16(UInt16(centralEntries.count), to: &archive)
        appendUInt16(UInt16(centralEntries.count), to: &archive)
        appendUInt32(centralDirectorySize, to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive) // archive comment length

        do {
            try archive.write(to: archiveURL, options: .atomic)
            return archiveURL
        } catch {
            return nil
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(truncatingIfNeeded: value), to: &data)
        appendUInt16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value >> 1) ^ (0xedb8_8320 &* (value & 1))
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffff_ffff
        let table = crc32Table
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xff)
            checksum = (checksum >> 8) ^ table[index]
        }
        return ~checksum
    }

    private func writeEvent(_ event: DiagnosticEvent, wall: Date) {
        if let key = Self.frameRunKey(for: event) {
            if var run = pendingFrameRun, run.key == key {
                run.lastEvent = event
                run.count += 1
                pendingFrameRun = run
                return
            }
            flushPendingFrameRun()
            appendRendered(event, wall: wall)
            pendingFrameRun = FrameRun(key: key, lastEvent: event, count: 1)
            return
        }
        flushPendingFrameRun()
        appendRendered(event, wall: wall)
    }

    /// Frame-pipeline events repeat at frame cadence with only the sequence
    /// and byte count varying; they coalesce per (code, panel, stage).
    private static func frameRunKey(for event: DiagnosticEvent) -> FrameRunKey? {
        guard event.code == .simulatorFrameLifecycle else { return nil }
        return FrameRunKey(code: event.code, surface: event.surface, stage: event.a)
    }

    private func flushPendingFrameRun() {
        guard let run = pendingFrameRun else { return }
        pendingFrameRun = nil
        guard run.count > 1 else { return }
        let summary = presentation.summary(run.lastEvent)
        append(
            line: "\(timestampFormatter.string(from: Date())) \(summary) (repeated ×\(run.count))",
            domain: run.key.code.appLogDomain
        )
    }

    private func appendRendered(_ event: DiagnosticEvent, wall: Date) {
        append(
            line: "\(timestampFormatter.string(from: wall)) \(presentation.summary(event))",
            domain: event.code.appLogDomain
        )
    }

    private func append(line: String, domain: Domain) {
        switch domain {
        case .app:
            appFile?.append(line)
        case .network:
            networkFile?.append(line)
        case .both:
            appFile?.append(line)
            networkFile?.append(line)
        }
    }
}

public extension DiagnosticEventCode {
    /// Which on-disk log this event belongs to: the app-wide log, the network
    /// diagnostics log, or both (cross-cutting context that keeps each file
    /// self-sufficient). New codes default to the app log.
    var appLogDomain: AppLog.Domain {
        switch self {
        case .connect, .pairOk, .pairFail, .pairUnreachable,
             .livenessResubscribe, .streamEnded, .inputSeqBehind, .byteGap,
             .transportDialStarted, .transportDialConnected, .transportDialFailed,
             .hostAuthenticated, .hostAuthenticationFailed,
             .rpcReady, .rpcFailed,
             .recoveryStarted, .recoverySucceeded, .recoveryFailed,
             .endpointStarting, .endpointActive, .endpointStopped, .endpointFailed,
             .relayPolicyRefreshStarted, .relayPolicyRefreshSucceeded,
             .relayPolicyRefreshFailed,
             .selectedPathChanged, .sessionClosed, .routeUnavailable,
             .retryScheduled,
             .discoveryStarted, .discoverySucceeded, .discoveryFailed,
             .admissionSucceeded, .admissionFailed,
             .transportSessionLifecycle,
             .transportCloseAttribution, .transportPathEvent,
             .transportDialPlanBuilt, .transportPrivateAddressJoin,
             .transportLANDiscovery, .transportDialLegSucceeded,
             .transportDialLegFailed, .lanPublicationState,
             .transportDialSessionLinked, .transportDialCancelled,
             .transportCloseReason:
            return .network
        case .appLifecycleChanged, .reachabilityChanged:
            return .both
        default:
            return .app
        }
    }
}
