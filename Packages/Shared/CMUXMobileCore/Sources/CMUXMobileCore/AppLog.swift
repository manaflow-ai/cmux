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
        // lint:allow lock - synchronous acknowledgement resolution is required
        // for cancellation and timeout races across producer tasks.
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
    /// never evict an entry that was already accepted. A small reserved control
    /// lane admits barriers and clears while the traffic queue drains.
    // lint:allow lock - synchronous admission is required for nonisolated
    // producers; the lock is held only while updating a bounded in-memory queue.
    private final class EntryIngress: @unchecked Sendable {
        private struct State: Sendable {
            var entries: [Entry] = []
            var bufferedDroppableCount = 0
            var finished = false
        }

        // lint:allow lock - synchronous admission is required for nonisolated
        // producers; the lock is held only while updating a bounded queue.
        private let lock = NSLock()
        private var state = State()
        private let maxBufferedEntries: Int
        private let maxBufferedControlEntries: Int
        private let wakeContinuation: AsyncStream<Void>.Continuation
        private var wakeIterator: AsyncStream<Void>.Iterator

        init(maxBufferedEntries: Int = 2_048) {
            self.maxBufferedEntries = max(1, maxBufferedEntries)
            self.maxBufferedControlEntries = 16
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
                    // Drop the incoming hot-path event when the droppable
                    // budget is full. Control admission may still evict an
                    // older droppable entry below, but event producers never
                    // scan or shift the queue while holding the lock.
                    guard state.bufferedDroppableCount < maxBufferedEntries else {
                        return false
                    }
                    state.bufferedDroppableCount += 1
                } else if state.entries.count >= maxBufferedEntries + maxBufferedControlEntries {
                    // A barrier or clear must not displace an already
                    // accepted event. The reserved control lane is bounded;
                    // exhaustion fails closed rather than losing traffic.
                    return false
                }
                state.entries.append(entry)
                return true
            }
            if admitted {
                wakeContinuation.yield(())
            } else {
                Self.resumeControl(entry, result: false)
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
                Self.resumeControl(entry, result: false)
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

        private static func resumeControl(_ entry: Entry, result: Bool) {
            switch entry {
            case .barrier(let acknowledgement), .clear(let acknowledgement):
                acknowledgement.signal(result)
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
                if FileManager.default.fileExists(atPath: url.path) {
                    openExistingForAppending()
                } else {
                    // The active generation may have been removed before a
                    // later archive failed. Recreate it without disturbing the
                    // archive that could not be deleted.
                    _ = openFreshGeneration()
                }
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
    private var exportSnapshotInProgress = false
    private var deferredExportEntries: [Entry] = []
    private var deferredExportDroppableCount = 0
    private var processed = 0
    private let presentation = DiagnosticEventPresentation()
    private let timestampFormatter: ISO8601DateFormatter
    private let ingress: EntryIngress
    private let supplementalAppLogURLs: @Sendable () -> [URL]
    private let flushSupplementalAppLog: @Sendable () async -> Bool
    private let supplementalAppLogSnapshot: @Sendable () async -> [Data]?

    private static let drainWaitTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let exportTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let ingressCapacity = 2_048
    private static let controlReserve = 16

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
        flushSupplementalAppLog: @escaping @Sendable () async -> Bool = { true },
        supplementalAppLogSnapshot: @escaping @Sendable () async -> [Data]? = { nil }
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
        self.supplementalAppLogURLs = supplementalAppLogURLs
        self.flushSupplementalAppLog = flushSupplementalAppLog
        self.supplementalAppLogSnapshot = supplementalAppLogSnapshot
        Self.removeStaleExportArchives()
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
        let ingress = EntryIngress(maxBufferedEntries: Self.ingressCapacity)
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

    private static func isDroppable(_ entry: Entry) -> Bool {
        switch entry {
        case .event, .appLine:
            return true
        case .barrier, .clear:
            return false
        }
    }

    private static func signalControl(_ entry: Entry, result: Bool) {
        switch entry {
        case .barrier(let acknowledgement), .clear(let acknowledgement):
            acknowledgement.signal(result)
        case .event, .appLine:
            break
        }
    }

    private func write(_ entry: Entry) {
        guard !exportSnapshotInProgress else {
            if Self.isDroppable(entry) {
                guard deferredExportEntries.count < Self.ingressCapacity + Self.controlReserve,
                      deferredExportDroppableCount < Self.ingressCapacity else { return }
                deferredExportDroppableCount += 1
            } else if deferredExportEntries.count >= Self.ingressCapacity + Self.controlReserve {
                Self.signalControl(entry, result: false)
                return
            }
            deferredExportEntries.append(entry)
            return
        }
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

        let completion = ExportCompletion()
        let exportTask = Task.detached(priority: .utility) { [self] in
            guard let inputs = await captureExportInputs() else {
                completion.resolve(nil)
                return
            }
            completion.resolve(Self.writeExportArchive(inputs: inputs))
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(nanoseconds: Self.exportTimeoutNanoseconds)
                completion.resolve(nil)
                exportTask.cancel()
            } catch {
                // The export completed before its deadline.
            }
        }
        let result = await withTaskCancellationHandler(operation: {
            await completion.wait()
        }, onCancel: {
            completion.resolve(nil)
            exportTask.cancel()
        })
        timeoutTask.cancel()
        _ = exportTask
        return result
    }

    /// Captures a stable generation list through AppLog actor ownership, then
    /// copies those files in a cancellable worker while the actor defers new
    /// writes. This keeps the settings task responsive without racing rotate.
    private func captureExportInputs() async -> ExportInputs? {
        guard appFile != nil || networkFile != nil else { return nil }
        exportSnapshotInProgress = true
        let appSourceURLs = appFile.map { Self.logFileURLs(for: $0.url) } ?? []
        let networkSourceURLs = networkFile.map { Self.logFileURLs(for: $0.url) } ?? []
        let supplementalSnapshot = await supplementalAppLogSnapshot()
        let supplementalSourceURLs = supplementalSnapshot == nil
            ? supplementalAppLogURLs()
            : []
        let copyTask = Task.detached(priority: .utility) {
            Self.makeSnapshotInputs(
                appSourceURLs: appSourceURLs,
                networkSourceURLs: networkSourceURLs,
                supplementalSourceURLs: supplementalSourceURLs,
                supplementalSnapshot: supplementalSnapshot
            )
        }
        let result = await withTaskCancellationHandler(operation: {
            await copyTask.value
        }, onCancel: {
            copyTask.cancel()
        })
        exportSnapshotInProgress = false
        let deferredEntries = deferredExportEntries
        deferredExportEntries.removeAll(keepingCapacity: true)
        deferredExportDroppableCount = 0
        for entry in deferredEntries {
            write(entry)
        }
        return result
    }

    /// Copies generations from a detached worker while the AppLog actor holds
    /// the source set stable by deferring writes. Copies are chunked so
    /// cancellation is observed between filesystem calls.
    private static func makeSnapshotInputs(
        appSourceURLs: [URL],
        networkSourceURLs: [URL],
        supplementalSourceURLs: [URL],
        supplementalSnapshot: [Data]?
    ) -> ExportInputs? {
        guard let snapshotDirectory = makeSnapshotDirectory(),
              let appGenerations = snapshotFiles(
                  appSourceURLs,
                  into: snapshotDirectory,
                  prefix: "app"
              ), let networkGenerations = snapshotFiles(
                  networkSourceURLs,
                  into: snapshotDirectory,
                  prefix: "network"
              ) else {
            return nil
        }
        let supplementalGenerations: [URL]
        if let supplementalSnapshot {
            guard let files = writeSnapshots(
                supplementalSnapshot,
                into: snapshotDirectory,
                prefix: "supplemental"
            ) else {
                try? FileManager.default.removeItem(at: snapshotDirectory)
                return nil
            }
            supplementalGenerations = files
        } else if supplementalSourceURLs.isEmpty {
            supplementalGenerations = []
        } else {
            guard let files = snapshotFiles(
                supplementalSourceURLs,
                into: snapshotDirectory,
                prefix: "supplemental"
            ) else {
                try? FileManager.default.removeItem(at: snapshotDirectory)
                return nil
            }
            supplementalGenerations = files
        }
        return ExportInputs(
            appGenerations: appGenerations,
            networkGenerations: networkGenerations,
            supplementalGenerations: supplementalGenerations,
            snapshotDirectory: snapshotDirectory
        )
    }

    private static func snapshotFiles(
        _ fileURLs: [URL],
        into directory: URL,
        prefix: String
    ) -> [URL]? {
        var snapshots: [URL] = []
        snapshots.reserveCapacity(fileURLs.count)
        for (index, fileURL) in fileURLs.enumerated() {
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            let destination = directory.appendingPathComponent("\(prefix)-\(index).log")
            guard copyFile(from: fileURL, to: destination) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            snapshots.append(destination)
        }
        return snapshots
    }

    private static func writeSnapshots(
        _ snapshots: [Data],
        into directory: URL,
        prefix: String
    ) -> [URL]? {
        var files: [URL] = []
        files.reserveCapacity(snapshots.count)
        for (index, data) in snapshots.enumerated() {
            guard !Task.isCancelled else { return nil }
            let destination = directory.appendingPathComponent("\(prefix)-\(index).log")
            do {
                try data.write(to: destination, options: .atomic)
                files.append(destination)
            } catch {
                return nil
            }
        }
        return files
    }

    private static func makeSnapshotDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diagnostics-snapshot-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            return nil
        }
    }

    private static func copyFile(from source: URL, to destination: URL) -> Bool {
        do {
            let sourceHandle = try FileHandle(forReadingFrom: source)
            defer { try? sourceHandle.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                return false
            }
            let destinationHandle = try FileHandle(forWritingTo: destination)
            defer { try? destinationHandle.close() }
            while !Task.isCancelled {
                let chunk = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { return true }
                try destinationHandle.write(contentsOf: chunk)
            }
            return false
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }

    /// Clears the structured log files, including all retained generations.
    /// Entries already admitted before this call are drained first, so a clear
    /// cannot be undone by an older write still waiting in the ingress stream.
    @discardableResult
    public func clear() async -> Bool {
        let acknowledgement = Acknowledgement()
        ingress.enqueue(.clear(acknowledgement))
        let didClear = await acknowledgement.wait(timeoutNanoseconds: Self.drainWaitTimeoutNanoseconds)
        if didClear {
            Self.removeStaleExportArchives()
        }
        return didClear
    }

    private struct ExportInputs: Sendable {
        let appGenerations: [URL]
        let networkGenerations: [URL]
        let supplementalGenerations: [URL]
        let snapshotDirectory: URL
    }

    /// Resolves the settings task independently from the detached ZIP writer.
    /// If a late worker finishes after cancellation or timeout, its temporary
    /// archive is removed instead of being left behind.
    private final class ExportCompletion: @unchecked Sendable {
        // lint:allow lock - this gate crosses the detached ZIP worker and the
        // cancellable settings task without actor affinity.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL?, Never>?
        private var result: URL??

        func wait() async -> URL? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ result: URL?) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                if let result {
                    try? FileManager.default.removeItem(at: result)
                }
                return
            }
            self.result = .some(result)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    /// Performs bounded export work away from the AppLog actor. Every stage
    /// checks cancellation and a monotonic deadline so a slow filesystem cannot
    /// keep the settings task occupied indefinitely.
    private static func writeExportArchive(inputs: ExportInputs) -> URL? {
        defer { try? FileManager.default.removeItem(at: inputs.snapshotDirectory) }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ exportTimeoutNanoseconds
        guard !Task.isCancelled,
              let writer = StreamingZipWriter() else {
            return nil
        }
        var completed = false
        defer {
            if !completed { writer.abort() }
        }
        guard streamMergedEntry(
            name: "\(Self.exportDirectoryName)/\(Self.exportAppFileName)",
            generations: inputs.appGenerations,
            additionalGenerations: inputs.supplementalGenerations,
            writer: writer,
            deadlineNanoseconds: deadline
        ), streamMergedEntry(
            name: "\(Self.exportDirectoryName)/\(Self.exportNetworkFileName)",
            generations: inputs.networkGenerations,
            writer: writer,
            deadlineNanoseconds: deadline
        ), !hasExpired(deadline),
              let archiveURL = writer.finish() else {
            return nil
        }
        completed = true
        return archiveURL
    }

    private static func hasExpired(_ deadlineNanoseconds: UInt64) -> Bool {
        Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
    }

    private static func streamMergedEntry(
        name: String,
        generations: [URL],
        additionalGenerations: [URL] = [],
        writer: StreamingZipWriter,
        deadlineNanoseconds: UInt64
    ) -> Bool {
        guard writer.beginEntry(name), !hasExpired(deadlineNanoseconds) else { return false }
        var lastByte: UInt8?
        var lineCollector = LineCollector(enabled: !additionalGenerations.isEmpty)
        for fileURL in generations.reversed() {
            guard streamFile(
                fileURL,
                to: writer,
                lineCollector: &lineCollector,
                lastByte: &lastByte,
                deadlineNanoseconds: deadlineNanoseconds
            ) else { return false }
            if lastByte != 0x0A {
                guard writer.append(Data([0x0A])) else { return false }
                lineCollector.consume(Data([0x0A]))
                lastByte = 0x0A
            }
        }
        lineCollector.finish()
        for fileURL in additionalGenerations.reversed() {
            guard streamLines(
                fileURL,
                to: writer,
                lineCollector: &lineCollector,
                lastByte: &lastByte,
                deadlineNanoseconds: deadlineNanoseconds
            ) else { return false }
        }
        return writer.finishEntry()
    }

    private struct ZipEntry {
        let name: String
        let byteCount: UInt32
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    /// Streams stored ZIP entries directly to disk. Data descriptors allow
    /// each log member to be written without first materializing its merged
    /// contents in a second in-memory buffer.
    private final class StreamingZipWriter {
        private struct ActiveEntry {
            let name: String
            let localHeaderOffset: UInt32
            var byteCount: UInt64 = 0
            var checksum: UInt32 = 0xffff_ffff
        }

        private let archiveURL: URL
        private let handle: FileHandle
        private var offset: UInt64 = 0
        private var activeEntry: ActiveEntry?
        private var centralEntries: [ZipEntry] = []

        init?() {
            archiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-diagnostics-\(UUID().uuidString).zip")
            guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: archiveURL) else {
                return nil
            }
            self.handle = handle
        }

        func beginEntry(_ name: String) -> Bool {
            guard activeEntry == nil,
                  let nameData = name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  offset <= UInt64(UInt32.max) else {
                return false
            }
            var header = Data()
            appendUInt32(0x0403_4b50, to: &header)
            appendUInt16(20, to: &header) // version needed to extract
            appendUInt16(0x0008, to: &header) // data descriptor follows
            appendUInt16(0, to: &header) // stored, no compression
            appendUInt16(0, to: &header) // DOS time
            appendUInt16(0, to: &header) // DOS date
            appendUInt32(0, to: &header) // CRC follows in descriptor
            appendUInt32(0, to: &header)
            appendUInt32(0, to: &header)
            appendUInt16(UInt16(nameData.count), to: &header)
            appendUInt16(0, to: &header) // extra field length
            header.append(nameData)
            guard write(header) else { return false }
            activeEntry = ActiveEntry(
                name: name,
                localHeaderOffset: UInt32(offset - UInt64(header.count))
            )
            return true
        }

        func append(_ data: Data) -> Bool {
            guard var activeEntry,
                  activeEntry.byteCount <= UInt64(UInt32.max) - UInt64(data.count),
                  offset <= UInt64(UInt32.max) - UInt64(data.count),
                  write(data) else {
                return false
            }
            for byte in data {
                let index = Int((activeEntry.checksum ^ UInt32(byte)) & 0xff)
                activeEntry.checksum = (activeEntry.checksum >> 8) ^ crc32Table[index]
            }
            activeEntry.byteCount += UInt64(data.count)
            self.activeEntry = activeEntry
            return true
        }

        func finishEntry() -> Bool {
            guard let activeEntry,
                  activeEntry.byteCount <= UInt64(UInt32.max),
                  offset <= UInt64(UInt32.max) else {
                return false
            }
            var descriptor = Data()
            appendUInt32(0x0807_4b50, to: &descriptor)
            appendUInt32(~activeEntry.checksum, to: &descriptor)
            appendUInt32(UInt32(activeEntry.byteCount), to: &descriptor)
            appendUInt32(UInt32(activeEntry.byteCount), to: &descriptor)
            guard write(descriptor) else { return false }
            centralEntries.append(ZipEntry(
                name: activeEntry.name,
                byteCount: UInt32(activeEntry.byteCount),
                crc32: ~activeEntry.checksum,
                localHeaderOffset: activeEntry.localHeaderOffset
            ))
            self.activeEntry = nil
            return true
        }

        func finish() -> URL? {
            guard activeEntry == nil,
                  offset <= UInt64(UInt32.max) else {
                return nil
            }
            let centralDirectoryOffset = UInt32(offset)
            var centralDirectorySize: UInt64 = 0
            for entry in centralEntries {
                guard let nameData = entry.name.data(using: .utf8),
                      nameData.count <= Int(UInt16.max) else {
                    return nil
                }
                var central = Data()
                appendUInt32(0x0201_4b50, to: &central)
                appendUInt16(20, to: &central) // version made by
                appendUInt16(20, to: &central) // version needed to extract
                appendUInt16(0x0808, to: &central) // UTF-8 + data descriptor
                appendUInt16(0, to: &central)
                appendUInt16(0, to: &central)
                appendUInt16(0, to: &central)
                appendUInt32(entry.crc32, to: &central)
                appendUInt32(entry.byteCount, to: &central)
                appendUInt32(entry.byteCount, to: &central)
                appendUInt16(UInt16(nameData.count), to: &central)
                appendUInt16(0, to: &central) // extra field length
                appendUInt16(0, to: &central) // comment length
                appendUInt16(0, to: &central) // disk number
                appendUInt16(0, to: &central) // internal attributes
                appendUInt32(0, to: &central) // external attributes
                appendUInt32(entry.localHeaderOffset, to: &central)
                central.append(nameData)
                guard write(central) else { return nil }
                centralDirectorySize += UInt64(central.count)
            }
            guard centralDirectorySize <= UInt64(UInt32.max),
                  offset <= UInt64(UInt32.max) else {
                return nil
            }
            var end = Data()
            appendUInt32(0x0605_4b50, to: &end)
            appendUInt16(0, to: &end) // disk number
            appendUInt16(0, to: &end) // central directory disk
            appendUInt16(UInt16(centralEntries.count), to: &end)
            appendUInt16(UInt16(centralEntries.count), to: &end)
            appendUInt32(UInt32(centralDirectorySize), to: &end)
            appendUInt32(centralDirectoryOffset, to: &end)
            appendUInt16(0, to: &end) // archive comment length
            guard write(end) else { return nil }
            try? handle.close()
            return archiveURL
        }

        func abort() {
            try? handle.close()
            try? FileManager.default.removeItem(at: archiveURL)
        }

        private func write(_ data: Data) -> Bool {
            do {
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
                return true
            } catch {
                return false
            }
        }
    }

    private struct LineCollector {
        private var lines: Set<String>?
        private var mirroredLines: Set<String>?
        private var pending = Data()

        init(enabled: Bool) {
            lines = enabled ? [] : nil
            mirroredLines = enabled ? [] : nil
        }

        mutating func consume(_ data: Data) {
            guard lines != nil else { return }
            for byte in data {
                if byte == 0x0A {
                    record(pending)
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending.append(byte)
                }
            }
        }

        mutating func finish() {
            guard !pending.isEmpty else { return }
            record(pending)
            pending.removeAll(keepingCapacity: true)
        }

        mutating func shouldAppend(_ line: Data) -> Bool {
            guard !line.isEmpty else { return false }
            let value = String(decoding: line, as: UTF8.self)
            guard !(lines?.contains(value) ?? false),
                  !(mirroredLines?.contains(value) ?? false) else {
                return false
            }
            record(line)
            return true
        }

        private mutating func record(_ line: Data) {
            guard !line.isEmpty, lines != nil else { return }
            let value = String(decoding: line, as: UTF8.self)
            lines?.insert(value)
            if let opening = value.firstIndex(of: "[") {
                let remainder = value[opening...]
                if remainder.contains("] ") {
                    mirroredLines?.insert(String(remainder))
                }
            }
        }
    }

    private static func streamFile(
        _ fileURL: URL,
        to writer: StreamingZipWriter,
        lineCollector: inout LineCollector,
        lastByte: inout UInt8?,
        deadlineNanoseconds: UInt64
    ) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            while !hasExpired(deadlineNanoseconds) {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { return true }
                guard writer.append(chunk) else { return false }
                lineCollector.consume(chunk)
                lastByte = chunk.last
            }
            return false
        } catch {
            return false
        }
    }

    private static func streamLines(
        _ fileURL: URL,
        to writer: StreamingZipWriter,
        lineCollector: inout LineCollector,
        lastByte: inout UInt8?,
        deadlineNanoseconds: UInt64
    ) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var pending = Data()
            func appendPendingLine() -> Bool {
                guard lineCollector.shouldAppend(pending) else {
                    pending.removeAll(keepingCapacity: true)
                    return true
                }
                if lastByte != 0x0A, !writer.append(Data([0x0A])) { return false }
                guard writer.append(pending), writer.append(Data([0x0A])) else { return false }
                lastByte = 0x0A
                pending.removeAll(keepingCapacity: true)
                return true
            }
            while !hasExpired(deadlineNanoseconds) {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    return pending.isEmpty || appendPendingLine()
                }
                for byte in chunk {
                    if byte == 0x0A {
                        guard appendPendingLine() else { return false }
                    } else {
                        pending.append(byte)
                    }
                }
            }
            return false
        } catch {
            return false
        }
    }

    private static func removeStaleExportArchives() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let staleBefore = Date().addingTimeInterval(-60 * 60)
        guard let names = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in names {
            let name = url.lastPathComponent
            guard name.hasPrefix("cmux-diagnostics-") else { continue }
            guard name.hasSuffix(".zip") || name.hasPrefix("cmux-diagnostics-snapshot-") else {
                continue
            }
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  modified < staleBefore else { continue }
            try? fileManager.removeItem(at: url)
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
