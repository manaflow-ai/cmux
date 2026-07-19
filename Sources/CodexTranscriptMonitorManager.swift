import CMUXAgentLaunch
import CmuxFoundation
import Darwin
import Foundation

/// Owns all active Codex transcript monitors as one bounded in-process service.
actor CodexTranscriptMonitorManager {
    typealias OwnerResolver = @Sendable (
        [String: CodexTranscriptMonitorTarget]
    ) async -> [String: CodexTranscriptMonitorOwnership]
    typealias EventSink = @Sendable (
        CodexTranscriptMonitorRequest,
        CodexTranscriptMonitorTarget,
        CodexTranscriptMonitorUpdate
    ) async -> Void
    typealias WatcherProvider = @Sendable ([String]) -> RecursivePathWatcher?

    private struct FileSignature: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct Monitor {
        let sequence: UInt64
        let request: CodexTranscriptMonitorRequest
        var target: CodexTranscriptMonitorTarget
        var transcriptPath: String?
        var transcriptSignature: FileSignature?
        var didAttemptTranscriptRead = false
        var leaseSignature: FileSignature?
        var didCheckLease = false
        var publishedCallIDs: Set<String> = []
        var nextOwnerCheck: Date
        let expiresAt: Date
    }

    private struct Emission {
        let request: CodexTranscriptMonitorRequest
        let target: CodexTranscriptMonitorTarget
        let update: CodexTranscriptMonitorUpdate
    }

    private struct ExpiryEntry {
        let date: Date
        let sessionID: String
        let sequence: UInt64
    }

    private static let expiryHeapCompactionMinimumCount = 256
    private static let expiryHeapActiveRatio = 3
    private static let expiryHeapStaleEntryCeiling = 4_096

    private let maximumMonitorCount: Int
    private let maximumMonitorAge: TimeInterval
    private let ownerCheckInterval: TimeInterval
    private let admissionBatchDelay: Duration
    private let watcherRebuildDelay: Duration
    private let clock: any FileWatchClock
    private let now: @Sendable () -> Date
    private let ownerResolver: OwnerResolver
    private let eventSink: EventSink
    private let watcherProvider: WatcherProvider
    private let scanner = CodexTranscriptMonitorScanner()

    private var monitorsBySessionID: [String: Monitor] = [:]
    private var nextSequence: UInt64 = 0
    private var expiryHeap: [ExpiryEntry] = []
    private var pendingAdmissionSessionIDs: Set<String> = []
    private var admissionBatchTask: Task<Void, Never>?
    private var watcher: RecursivePathWatcher?
    private var watcherEventsTask: Task<Void, Never>?
    private var watcherRebuildTask: Task<Void, Never>?
    private var watcherRebuildRequested = false
    private var ownerDeadlineTask: Task<Void, Never>?
    private var isShutDown = false

    init(
        maximumMonitorCount: Int = 4_096,
        maximumMonitorAge: TimeInterval = 4 * 60 * 60,
        ownerCheckInterval: TimeInterval = 60,
        admissionBatchDelay: Duration = .milliseconds(50),
        watcherRebuildDelay: Duration = .milliseconds(50),
        clock: any FileWatchClock = SystemFileWatchClock(),
        now: @escaping @Sendable () -> Date = Date.init,
        ownerResolver: @escaping OwnerResolver,
        eventSink: @escaping EventSink,
        watcherProvider: @escaping WatcherProvider = { RecursivePathWatcher(paths: $0) }
    ) {
        self.maximumMonitorCount = max(1, maximumMonitorCount)
        self.maximumMonitorAge = max(1, maximumMonitorAge)
        self.ownerCheckInterval = max(1, ownerCheckInterval)
        self.admissionBatchDelay = admissionBatchDelay
        self.watcherRebuildDelay = watcherRebuildDelay
        self.clock = clock
        self.now = now
        self.ownerResolver = ownerResolver
        self.eventSink = eventSink
        self.watcherProvider = watcherProvider
    }

    func start(_ request: CodexTranscriptMonitorRequest) async -> CodexTranscriptMonitorStartResult {
        guard !isShutDown, let workspaceID = UUID(uuidString: request.workspaceID) else {
            return .resourceExhausted(limit: maximumMonitorCount)
        }
        let surfaceID: UUID?
        if let rawSurfaceID = request.surfaceID {
            guard let parsedSurfaceID = UUID(uuidString: rawSurfaceID) else {
                return .resourceExhausted(limit: maximumMonitorCount)
            }
            surfaceID = parsedSurfaceID
        } else {
            surfaceID = nil
        }
        pruneExpiredMonitors()
        let existing = monitorsBySessionID[request.sessionID]
        let preservesExistingLease = existing.map {
            resolvedLeasePath($0.request) == resolvedLeasePath(request)
        } ?? false
        let replaced = removeMonitor(
            sessionID: request.sessionID,
            removeLease: !preservesExistingLease
        ) != nil

        if monitorsBySessionID.count >= maximumMonitorCount {
            pruneRetiredMonitorsAtCapacity()
            pruneExpiredMonitors()
            if monitorsBySessionID.count >= maximumMonitorCount {
                await refreshOwnerStates(force: true)
                guard !Task.isCancelled else {
                    return .resourceExhausted(limit: maximumMonitorCount)
                }
                pruneExpiredMonitors()
            }
        }
        guard monitorsBySessionID.count < maximumMonitorCount else {
            return .resourceExhausted(limit: maximumMonitorCount)
        }

        nextSequence &+= 1
        let currentDate = now()
        let target = CodexTranscriptMonitorTarget(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        monitorsBySessionID[request.sessionID] = Monitor(
            sequence: nextSequence,
            request: request,
            target: target,
            transcriptPath: request.transcriptPath.map { resolvedPath($0, request: request) },
            nextOwnerCheck: currentDate,
            expiresAt: currentDate.addingTimeInterval(maximumMonitorAge)
        )
        pushExpiry(ExpiryEntry(
            date: currentDate.addingTimeInterval(maximumMonitorAge),
            sessionID: request.sessionID,
            sequence: nextSequence
        ))
        compactExpiryHeapIfNeeded()
        scheduleAdmissionBatch(for: request.sessionID)
        scheduleWatcherRebuild()
        scheduleOwnerDeadlineIfNeeded()
        let activeCount = monitorsBySessionID.count
        return replaced ? .replaced(activeCount: activeCount) : .started(activeCount: activeCount)
    }

    func activeMonitorCount() -> Int {
        monitorsBySessionID.count
    }

    func activeTurnID(sessionID: String) -> String? {
        monitorsBySessionID[sessionID]?.request.turnID
    }

    func scanNow() async {
        await scan(sessionIDs: Array(monitorsBySessionID.keys))
    }

    func refreshOwnersNow() async {
        await refreshOwnerStates(force: true)
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        admissionBatchTask?.cancel()
        admissionBatchTask = nil
        pendingAdmissionSessionIDs.removeAll()
        watcherRebuildTask?.cancel()
        watcherRebuildTask = nil
        watcherRebuildRequested = false
        watcherEventsTask?.cancel()
        watcherEventsTask = nil
        ownerDeadlineTask?.cancel()
        ownerDeadlineTask = nil
        if let watcher { await watcher.stop() }
        self.watcher = nil
        for monitor in monitorsBySessionID.values {
            removeLease(for: monitor)
        }
        monitorsBySessionID.removeAll()
        expiryHeap.removeAll()
    }

    private func scan(sessionIDs: [String]) async {
        guard !isShutDown else { return }
        var emissions: [Emission] = []
        var watcherPathsChanged = false
        for (index, sessionID) in sessionIDs.enumerated() {
            if index > 0, index.isMultiple(of: 32) {
                await publishEmissions(emissions)
                emissions.removeAll(keepingCapacity: true)
                await Task.yield()
                guard !isShutDown, !Task.isCancelled else { return }
            }
            guard var monitor = monitorsBySessionID[sessionID] else { continue }
            if leaseChangedAndIsRetired(&monitor) || monitor.expiresAt <= now() {
                removeLease(for: monitor)
                monitorsBySessionID.removeValue(forKey: sessionID)
                watcherPathsChanged = true
                continue
            }

            if monitor.transcriptPath == nil,
               let path = findTranscriptPath(for: monitor.request) {
                monitor.transcriptPath = path
                monitor.transcriptSignature = nil
                monitor.didAttemptTranscriptRead = false
                watcherPathsChanged = true
            }
            guard let transcriptPath = monitor.transcriptPath else {
                monitorsBySessionID[sessionID] = monitor
                continue
            }

            let signature = fileSignature(transcriptPath)
            guard !monitor.didAttemptTranscriptRead || signature != monitor.transcriptSignature else {
                monitorsBySessionID[sessionID] = monitor
                continue
            }
            monitor.didAttemptTranscriptRead = true
            monitor.transcriptSignature = signature
            guard let lines = recentTextFileLines(path: transcriptPath, maximumBytes: 512 * 1024) else {
                monitor.transcriptPath = findTranscriptPath(for: monitor.request, excluding: transcriptPath)
                monitor.transcriptSignature = nil
                monitor.didAttemptTranscriptRead = false
                monitorsBySessionID[sessionID] = monitor
                watcherPathsChanged = true
                continue
            }

            let snapshot = scanner.scan(
                lines: lines,
                turnID: monitor.request.turnID,
                excludingCallIDs: monitor.publishedCallIDs
            )
            if let input = snapshot.userInput,
               monitor.publishedCallIDs.insert(input.callID).inserted {
                emissions.append(Emission(
                    request: monitor.request,
                    target: monitor.target,
                    update: .userInput(input)
                ))
            }
            switch snapshot.state {
            case .pending:
                monitorsBySessionID[sessionID] = monitor
            case .healthy:
                removeLease(for: monitor)
                monitorsBySessionID.removeValue(forKey: sessionID)
                watcherPathsChanged = true
            case .failure(let failure):
                emissions.append(Emission(
                    request: monitor.request,
                    target: monitor.target,
                    update: .failure(failure)
                ))
                removeLease(for: monitor)
                monitorsBySessionID.removeValue(forKey: sessionID)
                watcherPathsChanged = true
            }
        }
        if watcherPathsChanged { scheduleWatcherRebuild() }
        await publishEmissions(emissions)
    }

    private func publishEmissions(_ emissions: [Emission]) async {
        for emission in emissions {
            guard !isShutDown, !Task.isCancelled else { return }
            await eventSink(emission.request, emission.target, emission.update)
        }
    }

    private func refreshOwnerStates(
        sessionIDs requestedSessionIDs: Set<String>? = nil,
        force: Bool
    ) async {
        guard !isShutDown, !monitorsBySessionID.isEmpty else { return }
        pruneExpiredMonitors()
        let currentDate = now()
        let due = monitorsBySessionID.compactMap { sessionID, monitor -> (String, UInt64, CodexTranscriptMonitorTarget)? in
            guard requestedSessionIDs?.contains(sessionID) ?? true else { return nil }
            guard force || monitor.nextOwnerCheck <= currentDate else { return nil }
            return (sessionID, monitor.sequence, monitor.target)
        }
        guard !due.isEmpty else {
            scheduleOwnerDeadlineIfNeeded()
            return
        }
        let targets = Dictionary(uniqueKeysWithValues: due.map { ($0.0, $0.2) })
        let resolutions = await ownerResolver(targets)
        guard !isShutDown, !Task.isCancelled else { return }
        var watcherPathsChanged = false
        for (sessionID, sequence, _) in due {
            guard var monitor = monitorsBySessionID[sessionID], monitor.sequence == sequence else {
                continue
            }
            monitor.nextOwnerCheck = now().addingTimeInterval(ownerCheckInterval)
            switch resolutions[sessionID] ?? .unknown {
            case .alive(let target):
                monitor.target = target
                monitorsBySessionID[sessionID] = monitor
            case .gone:
                removeLease(for: monitor)
                monitorsBySessionID.removeValue(forKey: sessionID)
                watcherPathsChanged = true
            case .unknown:
                monitorsBySessionID[sessionID] = monitor
            }
        }
        if watcherPathsChanged { scheduleWatcherRebuild() }
        scheduleOwnerDeadlineIfNeeded()
    }

    private func scheduleAdmissionBatch(for sessionID: String) {
        guard !isShutDown else { return }
        pendingAdmissionSessionIDs.insert(sessionID)
        guard admissionBatchTask == nil else { return }
        let clock = self.clock
        let delay = admissionBatchDelay
        admissionBatchTask = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.processAdmissionBatches()
        }
    }

    private func processAdmissionBatches() async {
        while !isShutDown, !Task.isCancelled, !pendingAdmissionSessionIDs.isEmpty {
            let sessionIDs = pendingAdmissionSessionIDs
            pendingAdmissionSessionIDs.removeAll(keepingCapacity: true)
            await scan(sessionIDs: Array(sessionIDs))
            await refreshOwnerStates(sessionIDs: sessionIDs, force: true)
        }
        admissionBatchTask = nil
    }

    private func scheduleOwnerDeadlineIfNeeded() {
        guard !isShutDown, !monitorsBySessionID.isEmpty, ownerDeadlineTask == nil else { return }
        let clock = self.clock
        let interval = Duration.seconds(ownerCheckInterval)
        ownerDeadlineTask = Task { [weak self] in
            // This is the monitor's intended owner-liveness deadline. It is
            // cancellable and clock-injected, never a filesystem polling loop.
            try? await clock.sleep(for: interval)
            await self?.ownerDeadlineReached()
        }
    }

    private func ownerDeadlineReached() async {
        ownerDeadlineTask = nil
        await refreshOwnerStates(force: false)
    }

    private func scheduleWatcherRebuild() {
        guard !isShutDown else { return }
        watcherRebuildRequested = true
        guard watcherRebuildTask == nil else { return }
        let clock = self.clock
        let delay = watcherRebuildDelay
        watcherRebuildTask = Task { [weak self] in
            // One leading-edge delay coalesces a burst of prompt starts into
            // one stream replacement. Starts during rebuild set the request
            // bit and are covered by the same task's next pass.
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.processWatcherRebuildRequests()
        }
    }

    private func processWatcherRebuildRequests() async {
        while !isShutDown, !Task.isCancelled, watcherRebuildRequested {
            watcherRebuildRequested = false
            await rebuildWatcher()
        }
        watcherRebuildTask = nil
    }

    private func rebuildWatcher() async {
        watcherEventsTask?.cancel()
        watcherEventsTask = nil
        if let watcher { await watcher.stop() }
        watcher = nil
        let paths = watchedDirectories()
        guard !paths.isEmpty, let newWatcher = watcherProvider(paths) else { return }
        watcher = newWatcher
        let events = newWatcher.events
        watcherEventsTask = Task { [weak self] in
            for await _ in events {
                await self?.fileSystemChanged()
            }
        }
        // The post-install scan closes the since-now handoff gap: changes before
        // stream creation are visible here, and later changes trigger `events`.
        await scan(sessionIDs: Array(monitorsBySessionID.keys))
    }

    private func fileSystemChanged() async {
        await scan(sessionIDs: Array(monitorsBySessionID.keys))
    }

    private func watchedDirectories() -> [String] {
        var paths = Set<String>()
        for monitor in monitorsBySessionID.values {
            if let leasePath = monitor.request.leasePath {
                paths.insert((resolvedPath(leasePath, request: monitor.request) as NSString).deletingLastPathComponent)
            }
            if let transcriptPath = monitor.transcriptPath {
                paths.insert((transcriptPath as NSString).deletingLastPathComponent)
            } else {
                paths.insert(codexSessionsDirectory(for: monitor.request))
            }
        }
        return paths.sorted()
    }

    private func pruneRetiredMonitorsAtCapacity() {
        for sessionID in Array(monitorsBySessionID.keys) {
            guard var monitor = monitorsBySessionID[sessionID] else { continue }
            if leaseChangedAndIsRetired(&monitor, forceRead: true) {
                removeLease(for: monitor)
                monitorsBySessionID.removeValue(forKey: sessionID)
            } else {
                monitorsBySessionID[sessionID] = monitor
            }
        }
    }

    private func pruneExpiredMonitors() {
        let currentDate = now()
        while let first = expiryHeap.first, first.date <= currentDate {
            let expired = popExpiry()
            guard let monitor = monitorsBySessionID[expired.sessionID],
                  monitor.sequence == expired.sequence else { continue }
            removeLease(for: monitor)
            monitorsBySessionID.removeValue(forKey: expired.sessionID)
        }
    }

    @discardableResult
    private func removeMonitor(sessionID: String, removeLease: Bool) -> Monitor? {
        guard let monitor = monitorsBySessionID.removeValue(forKey: sessionID) else { return nil }
        if removeLease { self.removeLease(for: monitor) }
        return monitor
    }

    private func leaseChangedAndIsRetired(
        _ monitor: inout Monitor,
        forceRead: Bool = false
    ) -> Bool {
        guard let path = resolvedLeasePath(monitor.request) else { return false }
        let signature = fileSignature(path)
        guard forceRead || !monitor.didCheckLease || signature != monitor.leaseSignature else {
            return false
        }
        monitor.didCheckLease = true
        monitor.leaseSignature = signature
        guard signature != nil else { return true }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["retiredAt"].map { !($0 is NSNull) } ?? false
    }

    private func removeLease(for monitor: Monitor) {
        guard let path = resolvedLeasePath(monitor.request) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func resolvedLeasePath(_ request: CodexTranscriptMonitorRequest) -> String? {
        request.leasePath.map { resolvedPath($0, request: request) }
    }

    private func findTranscriptPath(
        for request: CodexTranscriptMonitorRequest,
        excluding excludedPath: String? = nil
    ) -> String? {
        let directory = codexSessionsDirectory(for: request)
        let fileManager = FileManager.default
        let sessionsURL = URL(fileURLWithPath: directory, isDirectory: true)
        var directories: [URL] = []
        var seenDirectories = Set<String>()
        func appendDirectory(_ url: URL) {
            if seenDirectories.insert(url.path).inserted { directories.append(url) }
        }
        appendDirectory(sessionsURL)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        for calendar in [Calendar.current, utcCalendar] {
            for dayOffset in -14...1 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now()) else { continue }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year, let month = components.month, let day = components.day else {
                    continue
                }
                appendDirectory(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                )
            }
        }
        var newest: (URL, Date)?
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.contains(request.sessionID) {
                guard file.path != excludedPath else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if let newestModificationDate = newest?.1 {
                    if modified > newestModificationDate { newest = (file, modified) }
                } else {
                    newest = (file, modified)
                }
            }
        }
        return newest?.0.path
    }

    private func codexSessionsDirectory(for request: CodexTranscriptMonitorRequest) -> String {
        let home = request.homeDirectory ?? NSHomeDirectory()
        let codexHome = request.codexHome ?? URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true).path
        return URL(
            fileURLWithPath: resolvedPath(codexHome, request: request),
            isDirectory: true
        ).appendingPathComponent("sessions", isDirectory: true).path
    }

    private func resolvedPath(_ path: String, request: CodexTranscriptMonitorRequest) -> String {
        let home = request.homeDirectory ?? NSHomeDirectory()
        let expanded: String
        if path == "~" {
            expanded = home
        } else if path.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            let base = request.workingDirectory ?? home
            expanded = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(path).path
        }
        return (expanded as NSString).standardizingPath
    }

    private func fileSignature(_ path: String) -> FileSignature? {
        var status = stat()
        guard Darwin.stat(path, &status) == 0 else { return nil }
        return FileSignature(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func recentTextFileLines(path: String, maximumBytes: UInt64) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var readStart = size > maximumBytes ? size - maximumBytes : 0
            try handle.seek(toOffset: readStart)
            guard var data = try handle.readToEnd(), !data.isEmpty else { return nil }
            let maximumWindow = maximumBytes > UInt64.max / 8 ? UInt64.max : maximumBytes * 8
            while readStart > 0, !completeLineExistsAfterBoundary(data), size - readStart < maximumWindow {
                let expansion = min(readStart, maximumBytes, maximumWindow - (size - readStart))
                guard expansion > 0 else { break }
                readStart -= expansion
                try handle.seek(toOffset: readStart)
                guard let expanded = try handle.readToEnd(), !expanded.isEmpty else { return nil }
                data = expanded
            }
            if readStart > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.components(separatedBy: "\n")
        } catch {
            return nil
        }
    }

    private func completeLineExistsAfterBoundary(_ data: Data) -> Bool {
        guard let newline = data.firstIndex(of: 0x0A) else { return false }
        return data[data.index(after: newline)...].contains { byte in
            byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x20
        }
    }

    private func pushExpiry(_ entry: ExpiryEntry) {
        expiryHeap.append(entry)
        var index = expiryHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard expiryHeap[index].date < expiryHeap[parent].date else { break }
            expiryHeap.swapAt(index, parent)
            index = parent
        }
    }

    private func compactExpiryHeapIfNeeded() {
        let activeCount = monitorsBySessionID.count
        guard expiryHeap.count > Self.expiryHeapCompactionMinimumCount else { return }
        let staleCount = max(0, expiryHeap.count - activeCount)
        let ratioLimit = max(
            Self.expiryHeapCompactionMinimumCount,
            activeCount * Self.expiryHeapActiveRatio
        )
        guard expiryHeap.count > ratioLimit
                || staleCount > Self.expiryHeapStaleEntryCeiling else {
            return
        }
        expiryHeap = monitorsBySessionID.map { sessionID, monitor in
            ExpiryEntry(date: monitor.expiresAt, sessionID: sessionID, sequence: monitor.sequence)
        }
        guard expiryHeap.count > 1 else { return }
        for index in stride(from: expiryHeap.count / 2 - 1, through: 0, by: -1) {
            siftExpiryDown(from: index)
        }
    }

    private func popExpiry() -> ExpiryEntry {
        let first = expiryHeap[0]
        let last = expiryHeap.removeLast()
        guard !expiryHeap.isEmpty else { return first }
        expiryHeap[0] = last
        siftExpiryDown(from: 0)
        return first
    }

    private func siftExpiryDown(from startIndex: Int) {
        var index = startIndex
        while true {
            let left = index * 2 + 1
            guard left < expiryHeap.count else { break }
            let right = left + 1
            let child = right < expiryHeap.count && expiryHeap[right].date < expiryHeap[left].date
                ? right
                : left
            guard expiryHeap[child].date < expiryHeap[index].date else { break }
            expiryHeap.swapAt(child, index)
            index = child
        }
    }
}
