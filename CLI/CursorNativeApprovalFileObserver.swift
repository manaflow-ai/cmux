import Darwin
import Dispatch
import Foundation

/// Observes Cursor's native policy log from a detached CLI child process.
final class CursorNativeApprovalFileObserver {
    private static let maximumTailBytes = 512 * 1024
    private static let maximumFutureBytes = 512 * 1024
    private static let maximumGenerationHeaderBytes = 16 * 1024
    private static let maximumLogDiscoveryEntries = 4_096
    private static let readChunkSize = 16 * 1024
    private static let timeoutSeconds = 8
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    private static let terminalVnodeEvents = UInt32(
        NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
    )

    private let logDirectory: URL
    private let processIdentity: AgentPIDProcessIdentity
    private let expectedToolCallId: String
    private let fileManager: FileManager
    private var offset: Int64 = 0
    private var pendingBytes = Data()
    private var futureByteCount = 0

    init(
        logDirectory: URL,
        processIdentity: AgentPIDProcessIdentity,
        expectedToolCallId: String,
        fileManager: FileManager = .default
    ) {
        self.logDirectory = logDirectory.standardizedFileURL
        self.processIdentity = processIdentity
        self.expectedToolCallId = expectedToolCallId
        self.fileManager = fileManager
    }

    func waitForDecision() -> CursorNativeApprovalObservationOutcome {
        let timeoutNanoseconds =
            UInt64(Self.timeoutSeconds) * Self.nanosecondsPerSecond
        let deadline = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(timeoutNanoseconds)
        guard !deadline.overflow else { return .unavailable }
        guard processIdentity.liveness == .live,
              let logPath = waitForLogPath(
                  deadlineUptimeNanoseconds: deadline.partialValue
              ) else {
            return .unavailable
        }
        let descriptor = open(logPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0, fileInfo.st_size >= 0 else {
            return .unavailable
        }
        let initialEnd = Int64(fileInfo.st_size)
        offset = max(0, initialEnd - Int64(Self.maximumTailBytes))
        if let decision = consumeBytes(
            descriptor: descriptor,
            through: initialEnd,
            byteBudget: Self.maximumTailBytes
        ) {
            return decision
        }
        // The initial tail is historical evidence. Clear its partial first
        // line and give future writes their own bounded observation budget.
        pendingBytes.removeAll(keepingCapacity: true)
        offset = initialEnd

        let eventQueue = kqueue()
        guard eventQueue >= 0 else { return .unavailable }
        defer { close(eventQueue) }
        var registration = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(
                NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB
                    | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
            ),
            data: 0,
            udata: nil
        )
        guard kevent(eventQueue, &registration, 1, nil, 0, nil) == 0 else {
            return .unavailable
        }

        while true {
            guard processIdentity.liveness == .live else {
                return .unavailable
            }
            switch consumeAvailableLines(descriptor: descriptor) {
            case .waiting:
                break
            case let .decision(outcome):
                return outcome
            case .unavailable:
                return .unavailable
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.partialValue else { return .unavailable }
            let remaining = deadline.partialValue - now
            var timeout = timespec(
                tv_sec: Int(remaining / Self.nanosecondsPerSecond),
                tv_nsec: Int(remaining % Self.nanosecondsPerSecond)
            )
            var event = kevent()
            let eventCount = kevent(
                eventQueue,
                nil,
                0,
                &event,
                1,
                &timeout
            )
            if eventCount < 0, errno == EINTR { continue }
            guard eventCount > 0,
                  event.flags & UInt16(EV_ERROR) == 0,
                  event.fflags & Self.terminalVnodeEvents == 0 else {
                return .unavailable
            }
        }
    }

    private func discoverLogPath(
        deadlineUptimeNanoseconds: UInt64
    ) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: logDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
            ],
            options: [
                .skipsHiddenFiles,
                .skipsSubdirectoryDescendants,
            ]
        ) else {
            return nil
        }
        let pidMarker = "-\(processIdentity.pid)-"
        var candidate: String?
        var inspectedEntryCount = 0
        while let object = enumerator.nextObject() {
            guard DispatchTime.now().uptimeNanoseconds
                    < deadlineUptimeNanoseconds else {
                return nil
            }
            inspectedEntryCount += 1
            guard inspectedEntryCount <= Self.maximumLogDiscoveryEntries,
                  let url = object as? URL else {
                return nil
            }
            guard url.pathExtension == "log",
                  url.lastPathComponent.contains(pidMarker),
                  isRegularLogFile(url),
                  logContainsExactProcessGeneration(at: url) else {
                continue
            }
            guard candidate == nil else { return nil }
            candidate = url.standardizedFileURL.path
        }
        // A process generation should own one native-policy log. Multiple
        // exact-PID candidates are ambiguous, so fail closed instead of using
        // filename or timestamp ordering to guess which session is current.
        guard DispatchTime.now().uptimeNanoseconds
                < deadlineUptimeNanoseconds else {
            return nil
        }
        return candidate
    }

    /// Rejects symlinks and non-regular files before opening a candidate log.
    /// The Cursor directory also contains `latest.log`, which is a symlink and
    /// has no independent process-generation proof.
    private func isRegularLogFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// Reads Cursor's bounded `debug-session-start` record and proves that the
    /// file was created by this exact PID generation. A filename and mtime are
    /// only heuristics: both can survive PID reuse or be rewritten by another
    /// process. Cursor records the PID and startup timestamp in the first JSON
    /// line, so an older generation's log fails the monotonic timestamp check.
    private func logContainsExactProcessGeneration(at url: URL) -> Bool {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var bytes = [UInt8](
            repeating: 0,
            count: Self.maximumGenerationHeaderBytes
        )
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count > 0 else { return false }
        let header = Data(bytes.prefix(count))
        for line in header.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line)
            ) as? [String: Any],
                  object["event"] as? String == "debug-session-start",
                  let pid = (object["pid"] as? NSNumber)?.int64Value,
                  pid == Int64(processIdentity.pid),
                  let startTime = object["startTime"] as? String,
                  let logStart = try? Date.ISO8601FormatStyle().parse(
                      startTime
                  ) else {
                continue
            }
            let expectedStart = Date(
                timeIntervalSince1970:
                    TimeInterval(processIdentity.startSeconds)
            ).addingTimeInterval(
                TimeInterval(processIdentity.startMicroseconds) / 1_000_000
            )
            return logStart >= expectedStart
        }
        return false
    }

    /// Waits for Cursor to create the exact-generation log without polling.
    /// The native policy record is often written after `preToolUse` launches
    /// this child, so a one-shot directory scan can otherwise miss a real
    /// approval forever. A kqueue watch keeps the retry bounded by the same
    /// observation deadline and wakes only when the directory changes.
    private func waitForLogPath(
        deadlineUptimeNanoseconds: UInt64
    ) -> String? {
        while true {
            guard processIdentity.liveness == .live else { return nil }
            if let existing = discoverLogPath(
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ) {
                return existing
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNanoseconds else { return nil }
            guard let watchDirectory = existingWatchDirectoryPath(),
                  waitForDirectoryChange(
                      at: watchDirectory,
                      deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                  ) else {
                return nil
            }
        }
    }

    /// Waits for one change to a currently existing ancestor directory. The
    /// descriptor is intentionally recreated after each event so a directory
    /// created beneath an ancestor is watched directly on the next pass.
    private func waitForDirectoryChange(
        at path: String,
        deadlineUptimeNanoseconds: UInt64
    ) -> Bool {
        let watchDescriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard watchDescriptor >= 0 else { return false }
        defer { close(watchDescriptor) }
        let eventQueue = kqueue()
        guard eventQueue >= 0 else { return false }
        defer { close(eventQueue) }
        var registration = kevent(
            ident: UInt(watchDescriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(
                NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB
                    | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
            ),
            data: 0,
            udata: nil
        )
        guard kevent(eventQueue, &registration, 1, nil, 0, nil) == 0 else {
            return false
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNanoseconds else { return false }
            let remaining = deadlineUptimeNanoseconds - now
            var timeout = timespec(
                tv_sec: Int(remaining / Self.nanosecondsPerSecond),
                tv_nsec: Int(remaining % Self.nanosecondsPerSecond)
            )
            var event = kevent()
            let eventCount = kevent(
                eventQueue,
                nil,
                0,
                &event,
                1,
                &timeout
            )
            if eventCount < 0, errno == EINTR { continue }
            guard eventCount > 0, event.flags & UInt16(EV_ERROR) == 0 else {
                return false
            }
            return true
        }
    }

    private func existingWatchDirectoryPath() -> String? {
        var candidate = logDirectory
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    private func consumeAvailableLines(
        descriptor: Int32
    ) -> CursorNativeApprovalFileReadResult {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_size >= offset else {
            return .unavailable
        }
        let remainingBudget = Self.maximumFutureBytes - futureByteCount
        guard remainingBudget > 0 else { return .unavailable }
        let end = min(
            Int64(fileInfo.st_size),
            offset + Int64(remainingBudget)
        )
        let previousOffset = offset
        if let decision = consumeBytes(
            descriptor: descriptor,
            through: end,
            byteBudget: remainingBudget
        ) {
            return .decision(decision)
        }
        futureByteCount += Int(offset - previousOffset)
        if Int64(fileInfo.st_size) > offset,
           futureByteCount >= Self.maximumFutureBytes {
            return .unavailable
        }
        return .waiting
    }

    private func consumeBytes(
        descriptor: Int32,
        through end: Int64,
        byteBudget: Int
    ) -> CursorNativeApprovalObservationOutcome? {
        var consumed = 0
        while offset < end, consumed < byteBudget {
            let requested = min(
                Self.readChunkSize,
                byteBudget - consumed,
                Int(end - offset)
            )
            var bytes = [UInt8](repeating: 0, count: requested)
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(
                    descriptor,
                    buffer.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += Int64(count)
            consumed += count
            pendingBytes.append(contentsOf: bytes.prefix(count))
            if let decision = consumeCompleteLines() { return decision }
        }
        return nil
    }

    private func consumeCompleteLines()
        -> CursorNativeApprovalObservationOutcome? {
        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            let lineData = pendingBytes[..<newline]
            pendingBytes.removeSubrange(...newline)
            guard let line = String(data: Data(lineData), encoding: .utf8),
                  let decision = AgentNativeApprovalLogDecision.classify(
                      line: line,
                      expectedToolCallId: expectedToolCallId
                  ) else {
                continue
            }
            switch decision {
            case .approvalRequested:
                return .approvalRequested
            case .autoApproved:
                return .autoApproved
            }
        }
        if pendingBytes.count > Self.maximumTailBytes {
            pendingBytes.removeAll(keepingCapacity: false)
        }
        return nil
    }
}
