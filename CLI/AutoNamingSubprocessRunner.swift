import Darwin
import Foundation

struct AutoNamingSubprocessRunner: Sendable {
    var maxOutputBytes: Int = 64 * 1024

    /// Runs a tool-disabled summarizer with deadline-aware stdin, bounded or
    /// discarded stdout, and process-group cleanup for descendants.
    func run(
        executable: String,
        arguments: [String],
        prompt: String,
        environment: [String: String],
        timeout: TimeInterval,
        failOnOutputOverflow: Bool = true,
        requireStdoutEOF: Bool = true
    ) -> String? {
        var stdinFDs = [Int32](repeating: -1, count: 2)
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        defer {
            for fd in stdinFDs + stdoutFDs where fd >= 0 {
                close(fd)
            }
        }
        guard pipe(&stdinFDs) == 0,
              pipe(&stdoutFDs) == 0 else {
            return nil
        }
        guard Self.moveFDAboveStdio(&stdinFDs[0]),
              Self.moveFDAboveStdio(&stdinFDs[1]),
              Self.moveFDAboveStdio(&stdoutFDs[0]),
              Self.moveFDAboveStdio(&stdoutFDs[1]) else {
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(&fileActions, stdinFDs[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO) == 0 else {
            return nil
        }
        let stderrResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, path, O_WRONLY, 0)
        }
        guard stderrResult == 0 else { return nil }
        for fd in stdinFDs + stdoutFDs {
            guard posix_spawn_file_actions_addclose(&fileActions, fd) == 0 else { return nil }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var spawnedPID: pid_t = 0
        let spawnResult = Self.withCStringArray(argv) { cArgv in
            Self.withCStringArray(envp) { cEnvp in
                executable.withCString { executablePath in
                    posix_spawn(&spawnedPID, executablePath, &fileActions, &attributes, cArgv, cEnvp)
                }
            }
        }
        guard spawnResult == 0, spawnedPID > 0 else { return nil }

        close(stdinFDs[0])
        stdinFDs[0] = -1
        close(stdoutFDs[1])
        stdoutFDs[1] = -1

        let promptData = prompt.data(using: .utf8) ?? Data()
        Self.configureWriteFDNoSIGPIPE(stdinFDs[1])
        let stdinFlags = fcntl(stdinFDs[1], F_GETFL, 0)
        if stdinFlags >= 0 {
            _ = fcntl(stdinFDs[1], F_SETFL, stdinFlags | O_NONBLOCK)
        }
        let stdoutFD = stdoutFDs[0]
        let stdoutFlags = fcntl(stdoutFD, F_GETFL, 0)
        if stdoutFlags >= 0 {
            _ = fcntl(stdoutFD, F_SETFL, stdoutFlags | O_NONBLOCK)
        }
        defer {
            if stdoutFlags >= 0 {
                _ = fcntl(stdoutFD, F_SETFL, stdoutFlags)
            }
        }

        var output = Data()
        let firstWait = waitForProcess(
            pid: spawnedPID,
            stdinFD: &stdinFDs[1],
            promptData: promptData,
            stdoutFD: stdoutFD,
            output: &output,
            timeout: timeout,
            failOnOutputOverflow: failOnOutputOverflow,
            requireStdoutEOF: requireStdoutEOF
        )
        closeFD(&stdinFDs[1])
        guard firstWait.outputWithinLimit else {
            terminateProcessGroup(pid: spawnedPID)
            return nil
        }
        guard firstWait.promptDelivered else {
            terminateProcessGroup(pid: spawnedPID)
            return nil
        }
        guard let rawStatus = firstWait.rawStatus else {
            terminateProcessGroup(pid: spawnedPID)
            return nil
        }
        forceCleanupProcessGroup(pid: spawnedPID)
        guard Self.normalizedTerminationStatus(rawStatus) == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }

    @discardableResult
    private func terminateProcessGroup(pid: pid_t) -> Int32? {
        signalProcessGroup(pid: pid, signal: SIGTERM)
        signalProcessGroup(pid: pid, signal: SIGKILL)
        return Self.waitForProcessExit(pid: pid, timeout: 1)
    }

    private func waitForProcess(
        pid: pid_t,
        stdinFD: inout Int32,
        promptData: Data,
        stdoutFD: Int32,
        output: inout Data,
        timeout: TimeInterval,
        failOnOutputOverflow: Bool,
        requireStdoutEOF: Bool
    ) -> (rawStatus: Int32?, outputWithinLimit: Bool, promptDelivered: Bool) {
        var stdoutEOF = false
        var stdoutOverflowed = false
        var promptOffset = 0
        var promptDelivered = promptData.isEmpty
        var reapedStatus: Int32?
        let deadline = Date().addingTimeInterval(timeout)
        if promptDelivered {
            closeFD(&stdinFD)
        }
        while true {
            if reapedStatus == nil {
                reapedStatus = Self.reapProcessIfExited(pid: pid)
            }
            if !stdoutEOF {
                let withinLimit = drainAvailableOutput(
                    from: stdoutFD,
                    into: &output,
                    reachedEOF: &stdoutEOF,
                    overflowed: &stdoutOverflowed,
                    failOnOverflow: failOnOutputOverflow
                )
                guard withinLimit else { return (nil, false, promptDelivered) }
            }
            if !promptDelivered {
                let writeResult = Self.writeAvailableInput(promptData, offset: &promptOffset, to: stdinFD)
                if writeResult.completed {
                    promptDelivered = true
                    closeFD(&stdinFD)
                } else if writeResult.failed {
                    closeFD(&stdinFD)
                    return (nil, true, false)
                }
            }
            if reapedStatus == nil {
                reapedStatus = Self.reapProcessIfExited(pid: pid)
            }
            if let rawStatus = reapedStatus {
                guard promptDelivered else {
                    closeFD(&stdinFD)
                    return (nil, true, false)
                }
                let postExitDrainDeadline = deadline
                if !stdoutEOF {
                    while true {
                        let withinLimit = drainAvailableOutput(
                            from: stdoutFD,
                            into: &output,
                            reachedEOF: &stdoutEOF,
                            overflowed: &stdoutOverflowed,
                            failOnOverflow: failOnOutputOverflow
                        )
                        guard withinLimit else { return (nil, false, true) }
                        if stdoutEOF { break }
                        let remaining = postExitDrainDeadline.timeIntervalSinceNow
                        if !requireStdoutEOF {
                            return (rawStatus, true, true)
                        }
                        guard remaining > 0 else { return (nil, true, true) }
                        Self.waitForPipeChange(stdoutFD: stdoutFD, stdinFD: nil, timeout: min(remaining, 0.05))
                    }
                }
                return (rawStatus, true, true)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (nil, true, promptDelivered) }
            if stdoutEOF && promptDelivered {
                Self.waitForProcessExitEvent(pid: pid, timeout: min(remaining, 0.25))
            } else {
                Self.waitForPipeChange(
                    stdoutFD: stdoutEOF ? nil : stdoutFD,
                    stdinFD: promptDelivered ? nil : stdinFD,
                    timeout: min(remaining, 0.25)
                )
            }
        }
    }

    private static func moveFDAboveStdio(_ fd: inout Int32) -> Bool {
        guard fd >= 0 else { return false }
        guard fd <= STDERR_FILENO else { return true }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard moved >= 0 else { return false }
        close(fd)
        fd = moved
        return true
    }

    private func closeFD(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static func writeAvailableInput(
        _ data: Data,
        offset: inout Int,
        to fd: Int32
    ) -> (completed: Bool, failed: Bool) {
        guard fd >= 0 else { return (false, true) }
        guard !data.isEmpty else { return (true, false) }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return (true, false)
            }
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return (false, true) }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return (false, false)
                default:
                    return (false, true)
                }
            }
            return (true, false)
        }
    }

    private func drainAvailableOutput(
        from fd: Int32,
        into output: inout Data,
        reachedEOF: inout Bool,
        overflowed: inout Bool,
        failOnOverflow: Bool
    ) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let readCount = Darwin.read(fd, &chunk, chunk.count)
            if readCount > 0 {
                if overflowed {
                    return true
                }
                guard output.count + readCount <= maxOutputBytes else {
                    output.removeAll(keepingCapacity: false)
                    overflowed = true
                    return !failOnOverflow
                }
                output.append(contentsOf: chunk.prefix(readCount))
                continue
            }
            if readCount == 0 {
                reachedEOF = true
                return true
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
    }

    private static func reapProcessIfExited(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1 && errno == EINTR { continue }
            if result == -1 && errno == ECHILD { return 0 }
            return nil
        }
    }

    private static func waitForProcessExit(pid: pid_t, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let rawStatus = reapProcessIfExited(pid: pid) {
                return rawStatus
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            waitForProcessExitEvent(pid: pid, timeout: min(remaining, 0.25))
        }
    }

    private static func normalizedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal != 0 { return 128 + signal }
        return (rawStatus >> 8) & 0xff
    }

    private func signalProcessGroup(pid: pid_t, signal: Int32, fallbackToProcess: Bool = true) {
        if kill(-pid, signal) != 0 {
            guard fallbackToProcess else { return }
            _ = kill(pid, signal)
        }
    }

    private func forceCleanupProcessGroup(pid: pid_t) {
        signalProcessGroup(pid: pid, signal: SIGTERM, fallbackToProcess: false)
        signalProcessGroup(pid: pid, signal: SIGKILL, fallbackToProcess: false)
    }

    private static func waitForProcessExitEvent(pid: pid_t, timeout: TimeInterval) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var registrationEvent = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD) | UInt16(EV_ENABLE) | UInt16(EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        var exitEvent = kevent()
        var timeoutSpec = timespec(timeout)
        _ = kevent(queue, &registrationEvent, 1, &exitEvent, 1, &timeoutSpec)
    }

    private static func waitForPipeChange(stdoutFD: Int32?, stdinFD: Int32?, timeout: TimeInterval) {
        var descriptors: [pollfd] = []
        if let stdoutFD {
            descriptors.append(pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
        }
        if let stdinFD {
            descriptors.append(pollfd(fd: stdinFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0))
        }
        guard !descriptors.isEmpty else { return }
        let timeoutMilliseconds = max(0, Int32((timeout * 1_000).rounded(.up)))
        while true {
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
            }
            if result >= 0 { return }
            if errno == EINTR { continue }
            return
        }
    }

    private static func timespec(_ timeout: TimeInterval) -> Darwin.timespec {
        let clamped = max(0, timeout)
        let seconds = Int(clamped)
        let nanoseconds = Int((clamped - TimeInterval(seconds)) * 1_000_000_000)
        return Darwin.timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    }

    private static func configureWriteFDNoSIGPIPE(_ fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
