import Darwin
import Foundation

struct GitProcessWaitPlan {
    let deadline: TimeInterval?

    init(
        processDeadline: TimeInterval,
        escalationDeadline: TimeInterval?,
        didSendSIGKILL: Bool,
        finalReapDeadline: TimeInterval?
    ) {
        deadline = didSendSIGKILL
            ? finalReapDeadline
            : escalationDeadline ?? processDeadline
    }
}

struct GitOutputCapTerminationState {
    private(set) var didTerminateForOutputCap = false

    mutating func record(didSignalLiveProcess: Bool) {
        didTerminateForOutputCap = didTerminateForOutputCap || didSignalLiveProcess
    }
}

/// Owns one subprocess from spawn through output drain, deadline escalation,
/// and reap. Kernel events and the caller's thread are the only scheduler: a
/// saturated dispatch or Swift-concurrency pool cannot delay the deadline.
struct GitSubprocessSupervisor {
    private static let sigkillGraceSeconds = 0.2
    private static let readChunkBytes = 64 * 1024

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let deadlineSeconds: Double
    let maxOutputBytes: Int?

    func run() -> GitProcessResult {
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        defer {
            for descriptor in outputPipe where descriptor >= 0 {
                close(descriptor)
            }
        }
        guard outputPipe.allSatisfy({ $0 > STDERR_FILENO }) else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var actionsReady = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0) == 0
        }
        actionsReady = actionsReady
            && posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO) == 0
        actionsReady = actionsReady && "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, $0, O_WRONLY, 0) == 0
        }
        actionsReady = actionsReady
            && posix_spawn_file_actions_addclose(&fileActions, outputPipe[0]) == 0
            && posix_spawn_file_actions_addclose(&fileActions, outputPipe[1]) == 0
        actionsReady = actionsReady && "/".withCString {
            posix_spawn_file_actions_addchdir_np(&fileActions, $0) == 0
        }
        guard actionsReady else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_START_SUSPENDED
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        let argv = [executableURL.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnStatus = Self.withCStringArray(argv) { argvPointer in
            Self.withCStringArray(envp) { environmentPointer in
                executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        close(outputPipe[1])
        outputPipe[1] = -1
        guard spawnStatus == 0, processIdentifier > 0 else {
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        let outputDescriptor = outputPipe[0]
        outputPipe[0] = -1
        return supervise(processIdentifier: processIdentifier, outputDescriptor: outputDescriptor)
    }

    private func supervise(
        processIdentifier: pid_t,
        outputDescriptor initialOutputDescriptor: Int32
    ) -> GitProcessResult {
        var outputDescriptor = initialOutputDescriptor
        defer {
            if outputDescriptor >= 0 { close(outputDescriptor) }
        }
        guard Self.makeNonblocking(outputDescriptor) else {
            Self.terminateAndReap(processIdentifier)
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        let eventQueue = kqueue()
        guard eventQueue >= 0 else {
            Self.terminateAndReap(processIdentifier)
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        defer { close(eventQueue) }

        var registrations = [
            kevent(
                ident: UInt(outputDescriptor),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            kevent(
                ident: UInt(processIdentifier),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            ),
        ]
        let registrationStatus = registrations.withUnsafeMutableBufferPointer { buffer in
            kevent(eventQueue, buffer.baseAddress, Int32(buffer.count), nil, 0, nil)
        }
        guard registrationStatus == 0 else {
            Self.terminateAndReap(processIdentifier)
            return GitProcessResult(output: nil, failure: .launchFailed)
        }
        let processDeadline = Self.uptime + max(0, deadlineSeconds)
        // Registration must win the race with a fast command such as `true`.
        // Starting suspended makes NOTE_EXIT observable before the child can
        // exit, then this supervisor is the only owner that resumes it.
        guard kill(processIdentifier, SIGCONT) == 0 else {
            Self.terminateAndReap(processIdentifier)
            return GitProcessResult(output: nil, failure: .launchFailed)
        }

        var output = Data()
        var capped = false
        var failure: GitProcessFailure?
        var processExited = false
        var escalationDeadline: TimeInterval?
        var didSendSIGKILL = false
        var finalReapDeadline: TimeInterval?
        var outputCapTermination = GitOutputCapTerminationState()

        @discardableResult
        func beginTermination(_ reason: GitProcessFailure?) -> Bool {
            guard escalationDeadline == nil else { return false }
            failure = reason
            let didSignalLiveProcess = !processExited && kill(-processIdentifier, SIGTERM) == 0
            escalationDeadline = Self.uptime + Self.sigkillGraceSeconds
            return didSignalLiveProcess
        }

        while !(processExited && outputDescriptor < 0) {
            if failure == nil, !capped, Task.isCancelled {
                beginTermination(.cancelled)
            }
            let now = Self.uptime
            if failure == nil, !capped, now >= processDeadline {
                beginTermination(.timedOut)
            }
            if let escalationDeadline, !didSendSIGKILL, now >= escalationDeadline {
                _ = kill(-processIdentifier, SIGKILL)
                didSendSIGKILL = true
                finalReapDeadline = now + Self.sigkillGraceSeconds
                if outputDescriptor >= 0 {
                    close(outputDescriptor)
                    outputDescriptor = -1
                }
            }
            if didSendSIGKILL,
               let finalReapDeadline,
               now >= finalReapDeadline,
               !processExited {
                // A process in uninterruptible kernel I/O may ignore even
                // SIGKILL. Transfer its eventual waitpid to a detached owner
                // so the request deadline remains real without leaking a
                // zombie when the kernel finally releases the child.
                reapProcessDetached(processIdentifier)
                return GitProcessResult(
                    rawOutput: output,
                    output: nil,
                    capped: capped,
                    terminatedForOutputCap: outputCapTermination.didTerminateForOutputCap,
                    failure: failure,
                    terminationStatus: nil
                )
            }

            if processExited && outputDescriptor < 0 { break }
            var events = [
                kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil),
                kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil),
            ]
            let waitPlan = GitProcessWaitPlan(
                processDeadline: processDeadline,
                escalationDeadline: escalationDeadline,
                didSendSIGKILL: didSendSIGKILL,
                finalReapDeadline: finalReapDeadline
            )
            guard let deadline = waitPlan.deadline else {
                reapProcessDetached(processIdentifier)
                return GitProcessResult(
                    rawOutput: output,
                    output: nil,
                    capped: capped,
                    terminatedForOutputCap: outputCapTermination.didTerminateForOutputCap,
                    failure: failure ?? .launchFailed,
                    terminationStatus: nil
                )
            }
            var timeout = Self.timespec(until: deadline)
            let eventCount = events.withUnsafeMutableBufferPointer { buffer in
                kevent(eventQueue, nil, 0, buffer.baseAddress, Int32(buffer.count), &timeout)
            }
            if eventCount < 0 {
                if errno == EINTR { continue }
                _ = kill(-processIdentifier, SIGKILL)
                if outputDescriptor >= 0 {
                    close(outputDescriptor)
                    outputDescriptor = -1
                }
                reapProcessDetached(processIdentifier)
                return GitProcessResult(
                    rawOutput: output,
                    output: nil,
                    capped: capped,
                    failure: failure ?? .launchFailed
                )
            }
            if eventCount == 0 { continue }

            for event in events.prefix(Int(eventCount)) {
                if event.filter == Int16(EVFILT_PROC) {
                    processExited = true
                } else if event.filter == Int16(EVFILT_READ), outputDescriptor >= 0 {
                    let reachedEnd = Self.drain(
                        outputDescriptor,
                        into: &output,
                        maxOutputBytes: maxOutputBytes,
                        capped: &capped
                    )
                    if capped {
                        outputCapTermination.record(
                            didSignalLiveProcess: beginTermination(nil)
                        )
                    }
                    if reachedEnd || (event.flags & UInt16(EV_EOF)) != 0 {
                        close(outputDescriptor)
                        outputDescriptor = -1
                    }
                }
            }
        }

        let terminationStatus = Self.reap(processIdentifier)
        return GitProcessResult(
            rawOutput: output,
            output: nil,
            capped: capped,
            terminatedForOutputCap: outputCapTermination.didTerminateForOutputCap,
            failure: failure,
            terminationStatus: terminationStatus
        )
    }

    private static var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func timespec(until deadline: TimeInterval) -> timespec {
        let remaining = max(0, deadline - uptime)
        return Darwin.timespec(
            tv_sec: Int(remaining),
            tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
        )
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Reads every currently available byte. `true` means EOF or an
    /// unrecoverable read error, so the caller should close its descriptor.
    private static func drain(
        _ descriptor: Int32,
        into output: inout Data,
        maxOutputBytes: Int?,
        capped: inout Bool
    ) -> Bool {
        var chunk = [UInt8](repeating: 0, count: readChunkBytes)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, readChunkBytes)
            }
            if count > 0 {
                if let maxOutputBytes {
                    let remaining = max(0, maxOutputBytes - output.count)
                    output.append(contentsOf: chunk.prefix(min(count, remaining)))
                    if count > remaining || output.count >= maxOutputBytes {
                        capped = true
                        return false
                    }
                } else {
                    output.append(contentsOf: chunk.prefix(count))
                }
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            return true
        }
    }

    private static func terminateAndReap(_ processIdentifier: pid_t) {
        _ = kill(-processIdentifier, SIGKILL)
        _ = reap(processIdentifier)
    }

    private static func reap(_ processIdentifier: pid_t) -> Int32? {
        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &rawStatus, 0)
            if result == processIdentifier { break }
            if result == -1, errno == EINTR { continue }
            return nil
        }
        if rawStatus & 0x7f == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return rawStatus & 0x7f
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

/// Owns the one remaining blocking wait after request supervision gives up.
/// One detached thread corresponds to one kernel-live child and exits as soon
/// as that child can be reaped.
private func reapProcessDetached(_ processIdentifier: pid_t) {
    Thread.detachNewThread {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
    }
}
