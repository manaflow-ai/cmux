import Darwin
import Foundation

/// Owns one suspended, child-led Git process group and its hard deadline.
///
/// This low-level POSIX bridge closes the output descriptor from deadline
/// callbacks and reaps only after a bounded `SIGTERM`/`SIGKILL` escalation.
// Safety: all mutable state shared by callbacks and the reader is protected by `stateLock`.
final class WorkspaceChangesGitProcess: @unchecked Sendable {
    struct ReadResult: Sendable {
        let wasTruncated: Bool
    }

    struct Exit: Sendable {
        let exitCode: Int32
        let timedOut: Bool
        let wasSignaled: Bool
    }

    private static let terminationGrace: TimeInterval = 2
    private static let exitMargin: TimeInterval = 1

    private let processIdentifier: pid_t
    private let hardDeadline: DispatchTime
    // Synchronizes short process-source/timer callbacks with the blocking reader; actor hops cannot close the descriptor synchronously.
    private let stateLock = NSLock()
    private let exitSignal = DispatchSemaphore(value: 0)
    private let escalationSignal = DispatchSemaphore(value: 0)
    private var readFileDescriptor: Int32
    private var didExit = false
    private var didStartTermination = false
    private var didEscalate = false
    private var timedOut = false
    private var terminationStartedAt: DispatchTime?
    private var reapedStatus: (exitCode: Int32, wasSignaled: Bool)?
    private var deadlineTimer: (any DispatchSourceTimer)?
    private var killTimer: (any DispatchSourceTimer)?
    private var exitSource: (any DispatchSourceProcess)?

    private init(
        processIdentifier: pid_t,
        readFileDescriptor: Int32,
        wallTimeLimit: TimeInterval
    ) {
        self.processIdentifier = processIdentifier
        self.readFileDescriptor = readFileDescriptor
        hardDeadline = .now() + wallTimeLimit
        installExitSource()
        installDeadlineTimer()
    }

    deinit {
        deadlineTimer?.cancel()
        killTimer?.cancel()
        exitSource?.cancel()
        closeReadEnd()
    }

    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        wallTimeLimit: TimeInterval
    ) throws -> WorkspaceChangesGitProcess {
        var outputFDs: [Int32] = [-1, -1]
        defer {
            for fileDescriptor in outputFDs where fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
            }
        }
        try throwIfPOSIXError(Darwin.pipe(&outputFDs))
        guard outputFDs.allSatisfy({ $0 > STDERR_FILENO }) else {
            throw POSIXError(.EBADF)
        }

        var fileActions: posix_spawn_file_actions_t?
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try "/dev/null".withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            )
            try throwIfPOSIXError(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDERR_FILENO,
                    path,
                    O_WRONLY,
                    0
                )
            )
        }
        try directory.path.withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            )
        }
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                outputFDs[1],
                STDOUT_FILENO
            )
        )
        for fileDescriptor in outputFDs {
            try throwIfPOSIXError(
                posix_spawn_file_actions_addclose(&fileActions, fileDescriptor)
            )
        }

        var attributes: posix_spawnattr_t?
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        try throwIfPOSIXError(posix_spawnattr_setflags(&attributes, flags))
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))

        let executablePath = executableURL.path
        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var spawnedPID: pid_t = 0
        let spawnStatus = withCStringArray(argumentStrings) { argv in
            withCStringArray(environmentStrings) { envp in
                executablePath.withCString { path in
                    posix_spawn(
                        &spawnedPID,
                        path,
                        &fileActions,
                        &attributes,
                        argv,
                        envp
                    )
                }
            }
        }
        try throwIfPOSIXError(spawnStatus)

        Darwin.close(outputFDs[1])
        outputFDs[1] = -1
        let process = WorkspaceChangesGitProcess(
            processIdentifier: spawnedPID,
            readFileDescriptor: outputFDs[0],
            wallTimeLimit: wallTimeLimit
        )
        outputFDs[0] = -1
        guard Darwin.kill(spawnedPID, SIGCONT) == 0 else {
            process.terminateForBoundedRead()
            _ = process.finish()
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return process
    }

    func readOutput(
        maximumByteCount: Int64,
        chunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws -> ReadResult {
        let descriptor = stateLock.withLock { readFileDescriptor }
        guard descriptor >= 0 else {
            return ReadResult(wasTruncated: true)
        }
        var consumedByteCount: Int64 = 0
        var wasTruncated = false
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        while !Task.isCancelled {
            let remaining = maximumByteCount - consumedByteCount
            let probeLimit = remaining == Int64.max ? remaining : remaining + 1
            let requestedCount = remaining > 0
                ? min(
                    chunkByteCount,
                    Int(min(probeLimit, Int64(Int.max)))
                )
                : 1
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count > 0 {
                let acceptedCount = min(
                    count,
                    Int(min(max(remaining, 0), Int64(Int.max)))
                )
                if acceptedCount > 0 {
                    try consume(Data(buffer.prefix(acceptedCount)))
                    consumedByteCount += Int64(acceptedCount)
                }
                if acceptedCount < count {
                    wasTruncated = true
                    break
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        if Task.isCancelled {
            wasTruncated = true
        }
        closeReadEnd()
        return ReadResult(wasTruncated: wasTruncated)
    }

    func terminateForBoundedRead() {
        beginTermination(isDeadline: false)
    }

    func finish() -> Exit {
        let initialTerminationStart = stateLock.withLock { terminationStartedAt }
        let absoluteExitBound = (initialTerminationStart ?? hardDeadline)
            + Self.terminationGrace
            + Self.exitMargin
        _ = exitSignal.wait(timeout: absoluteExitBound)

        let terminationStart = stateLock.withLock { terminationStartedAt }
        if let terminationStart {
            _ = escalationSignal.wait(
                timeout: terminationStart
                    + Self.terminationGrace
                    + Self.exitMargin
            )
        }

        let exited = stateLock.withLock { didExit }
        if !exited {
            forceKill()
            _ = exitSignal.wait(timeout: .now() + Self.exitMargin)
        }
        let status = stateLock.withLock { reapedStatus } ?? reapExitedLeader()
        let outcome = stateLock.withLock {
            (
                timedOut: timedOut,
                didStartTermination: didStartTermination
            )
        }
        let sources = stateLock.withLock {
            let sources = (deadlineTimer, killTimer, exitSource)
            deadlineTimer = nil
            killTimer = nil
            exitSource = nil
            return sources
        }
        sources.0?.cancel()
        sources.1?.cancel()
        sources.2?.cancel()
        closeReadEnd()
        return Exit(
            exitCode: status.exitCode,
            timedOut: outcome.timedOut,
            wasSignaled: status.wasSignaled || outcome.didStartTermination
        )
    }

    private func installExitSource() {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            stateLock.withLock {
                didExit = true
            }
            let status = reapExitedLeader()
            let processGroupIsGone = isProcessGroupGone()
            let shouldEndEscalationWait = stateLock.withLock {
                reapedStatus = status
                guard processGroupIsGone, didStartTermination, !didEscalate else {
                    return false
                }
                didEscalate = true
                killTimer?.cancel()
                killTimer = nil
                return true
            }
            if shouldEndEscalationWait {
                escalationSignal.signal()
            }
            exitSignal.signal()
        }
        exitSource = source
        source.resume()
    }

    private func installDeadlineTimer() {
        // A one-shot source is required because a synchronous pipe read needs an out-of-band deadline.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: hardDeadline)
        timer.setEventHandler { [weak self] in
            self?.beginTermination(isDeadline: true)
        }
        deadlineTimer = timer
        timer.resume()
    }

    private func beginTermination(isDeadline: Bool) {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !didExit else { return false }
            if isDeadline {
                timedOut = true
            }
            guard !didStartTermination else { return false }
            didStartTermination = true
            terminationStartedAt = .now()
            return true
        }
        closeReadEnd()
        guard shouldStart else { return }
        _ = Darwin.kill(-processIdentifier, SIGTERM)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.terminationGrace)
        timer.setEventHandler { [weak self] in
            self?.forceKill()
        }
        stateLock.withLock {
            killTimer = timer
        }
        timer.resume()
    }

    private func forceKill() {
        let shouldSignal = stateLock.withLock { () -> Bool in
            guard !didEscalate else { return false }
            didEscalate = true
            return true
        }
        guard shouldSignal else { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        escalationSignal.signal()
    }

    private func isProcessGroupGone() -> Bool {
        guard Darwin.kill(-processIdentifier, 0) == -1 else { return false }
        return errno == ESRCH
    }

    private func closeReadEnd() {
        let descriptor = stateLock.withLock { () -> Int32 in
            let descriptor = readFileDescriptor
            readFileDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func reapExitedLeader() -> (exitCode: Int32, wasSignaled: Bool) {
        var status: Int32 = 0
        let mayBlock = stateLock.withLock { didExit }
        let options = mayBlock ? 0 : WNOHANG
        while true {
            let result = Darwin.waitpid(processIdentifier, &status, options)
            if result == processIdentifier {
                let signal = status & 0x7f
                if signal == 0 {
                    return ((status >> 8) & 0xff, false)
                }
                return (128 + signal, true)
            }
            if result == -1, errno == EINTR {
                continue
            }
            return (128 + SIGKILL, true)
        }
    }

    private static func throwIfPOSIXError(_ result: Int32) throws {
        guard result != 0 else { return }
        throw POSIXError(.init(rawValue: result) ?? .EIO)
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
