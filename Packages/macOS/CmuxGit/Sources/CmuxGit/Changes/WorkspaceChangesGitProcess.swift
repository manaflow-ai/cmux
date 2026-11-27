import Darwin
import Foundation

/// Owns one suspended, child-led Git process group and its hard deadline.
///
/// This low-level POSIX bridge polls a nonblocking output descriptor, drives
/// group-wide `SIGTERM`/`SIGKILL` escalation, and reaps the process-group leader.
final class WorkspaceChangesGitProcess {
    struct ReadResult: Sendable {
        let wasTruncated: Bool
    }

    struct Exit: Sendable {
        let exitCode: Int32
        let timedOut: Bool
        let wasSignaled: Bool
    }

    private static let terminationGrace: TimeInterval = 2
    private static let pollIntervalMilliseconds: Int32 = 50

    private let processIdentifier: pid_t
    private let hardDeadline: DispatchTime
    private var readFileDescriptor: Int32
    private var didStartTermination = false
    private var timedOut = false
    private var terminationStartedAt: DispatchTime?
    private var reapedStatus: (exitCode: Int32, wasSignaled: Bool)?

    private init(
        processIdentifier: pid_t,
        readFileDescriptor: Int32,
        wallTimeLimit: TimeInterval
    ) {
        self.processIdentifier = processIdentifier
        self.readFileDescriptor = readFileDescriptor
        hardDeadline = .now() + wallTimeLimit
    }

    deinit {
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
        let descriptorFlags = Darwin.fcntl(outputFDs[0], F_GETFL)
        guard descriptorFlags >= 0,
              Darwin.fcntl(outputFDs[0], F_SETFL, descriptorFlags | O_NONBLOCK) == 0
        else {
            let savedErrno = errno
            _ = Darwin.killpg(spawnedPID, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(spawnedPID, &status, 0)
            throw POSIXError(.init(rawValue: savedErrno) ?? .EIO)
        }
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
        let descriptor = readFileDescriptor
        guard descriptor >= 0 else {
            return ReadResult(wasTruncated: true)
        }
        var consumedByteCount: Int64 = 0
        var wasTruncated = false
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        while true {
            updateProcessGroupLifecycle()
            if WorkspaceChangesCancellationSignal.isCurrentCancelled {
                wasTruncated = true
                beginTermination(isDeadline: false)
            }

            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptorState,
                1,
                nextPollTimeoutMilliseconds()
            )
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                wasTruncated = true
                break
            }
            if descriptorState.revents & Int16(POLLNVAL) != 0 {
                wasTruncated = true
                break
            }

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
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                wasTruncated = true
                break
            }
        }
        closeReadEnd()
        return ReadResult(wasTruncated: wasTruncated)
    }

    func terminateForBoundedRead() {
        beginTermination(isDeadline: false)
    }

    func finish() -> Exit {
        closeReadEnd()
        while true {
            updateProcessGroupLifecycle()
            if reapedStatus != nil, !isProcessGroupAlive() {
                break
            }
            _ = Darwin.poll(nil, 0, nextPollTimeoutMilliseconds())
        }
        let status = reapedStatus ?? (128 + SIGKILL, true)
        return Exit(
            exitCode: status.exitCode,
            timedOut: timedOut,
            wasSignaled: status.wasSignaled || didStartTermination
        )
    }

    private func updateProcessGroupLifecycle() {
        reapLeaderIfExited()
        let now = DispatchTime.now()
        if now >= hardDeadline, isProcessGroupAlive() {
            beginTermination(isDeadline: true)
        }
        guard let terminationStartedAt,
              now >= terminationStartedAt + Self.terminationGrace,
              isProcessGroupAlive() else { return }
        _ = Darwin.killpg(processIdentifier, SIGKILL)
    }

    private func beginTermination(isDeadline: Bool) {
        if isDeadline {
            timedOut = true
        }
        guard isProcessGroupAlive() else { return }
        if !didStartTermination {
            didStartTermination = true
            terminationStartedAt = .now()
        }
        _ = Darwin.killpg(processIdentifier, SIGTERM)
    }

    private func isProcessGroupAlive() -> Bool {
        guard Darwin.killpg(processIdentifier, 0) == -1 else { return true }
        return errno != ESRCH
    }

    private func closeReadEnd() {
        let descriptor = readFileDescriptor
        readFileDescriptor = -1
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func reapLeaderIfExited() {
        guard reapedStatus == nil else { return }
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                reapedStatus = Self.exitStatus(from: status)
                return
            }
            if result == -1, errno == EINTR { continue }
            return
        }
    }

    private func nextPollTimeoutMilliseconds() -> Int32 {
        let now = DispatchTime.now()
        let nextBoundary: DispatchTime
        if let terminationStartedAt,
           now < terminationStartedAt + Self.terminationGrace {
            nextBoundary = terminationStartedAt + Self.terminationGrace
        } else {
            nextBoundary = hardDeadline
        }
        guard nextBoundary > now else {
            return Self.pollIntervalMilliseconds
        }
        let remainingNanoseconds = nextBoundary.uptimeNanoseconds - now.uptimeNanoseconds
        let remainingMilliseconds = max(
            1,
            Int32(min(remainingNanoseconds / 1_000_000, UInt64(Int32.max)))
        )
        return min(Self.pollIntervalMilliseconds, remainingMilliseconds)
    }

    private static func exitStatus(
        from status: Int32
    ) -> (exitCode: Int32, wasSignaled: Bool) {
        let signal = status & 0x7f
        if signal == 0 {
            return ((status >> 8) & 0xff, false)
        }
        return (128 + signal, true)
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
