import Darwin
import Foundation

/// Owns one shell process and its child process group.
///
/// The shell is launched suspended in a child-led process group. That gives the
/// exit watcher time to attach before execution starts and lets every exit path
/// signal descendants as well as the shell itself.
actor AutomationProcessSession {
    private let command: String
    private let environment: [String: String]
    private var processIdentifier: pid_t?
    private var processGroupIdentifier: pid_t?
    private var processExitSource: DispatchSourceProcess?
    private var timeoutSource: DispatchSourceTimer?
    private var continuation: AsyncStream<Int32>.Continuation?
    private var terminationReason: AutomationProcessTerminationReason?
    private var finished = false

    init(command: String, environment: [String: String]) {
        self.command = command
        self.environment = environment
    }

    /// Runs the command and returns after the shell and all owned descendants
    /// have been signalled and the shell has been reaped.
    func run(timeoutSeconds: TimeInterval = 60) async -> AutomationActionExecutionResult {
        guard !finished else { return .failure("process session was already used") }

        let (stream, continuation) = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation

        guard let spawned = spawnProcess() else {
            finish(status: nil)
            return .failure("could not prepare automation command")
        }
        processIdentifier = spawned.processIdentifier
        processGroupIdentifier = spawned.processGroupIdentifier

        let exitSource = DispatchSource.makeProcessSource(
            identifier: spawned.processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        exitSource.setEventHandler { [weak self] in
            Task { await self?.processDidExit() }
        }
        processExitSource = exitSource
        exitSource.resume()

        installTimeoutSource(seconds: timeoutSeconds)

        // POSIX_SPAWN_START_SUSPENDED keeps the process from running until the
        // exit source above is armed, so even a command that exits immediately
        // remains inside the owned lifecycle boundary.
        if Darwin.kill(spawned.processIdentifier, SIGCONT) != 0 {
            terminate(reason: .cancelled)
        }
        if Task.isCancelled {
            terminate(reason: .cancelled)
        }

        for await status in stream {
            let reason = terminationReason
            switch reason {
            case .cancelled:
                return .failure("automation command cancelled")
            case .timedOut:
                return .failure("command timed out after \(timeoutSeconds) seconds")
            case nil:
                if status & 0x7f == 0 {
                    let exitCode = (status >> 8) & 0xff
                    return exitCode == 0
                        ? .success("command completed")
                        : .failure("command exited with status \(exitCode)")
                }
                return .failure("command terminated by signal \(status & 0x7f)")
            }
        }
        return .failure("process ended without a termination status")
    }

    /// Requests cancellation from a task cancellation handler without making
    /// the caller await an actor hop.
    nonisolated func cancel() {
        Task { await terminate(reason: .cancelled) }
    }

    private func installTimeoutSource(seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let milliseconds = Int(min(max(seconds, 0.1), 300) * 1_000)
        // This is a genuine command deadline, not synchronization or polling.
        // The one-shot source is cancelled as soon as the process exits.
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [weak self] in
            Task { await self?.terminate(reason: .timedOut) }
        }
        timeoutSource = timer
        timer.resume()
    }

    private func terminate(reason: AutomationProcessTerminationReason) {
        guard !finished else { return }
        if terminationReason == nil {
            terminationReason = reason
        }
        guard let processIdentifier, processIdentifier > 1 else { return }
        if let processGroupIdentifier, processGroupIdentifier > 1 {
            _ = Darwin.kill(-processGroupIdentifier, SIGTERM)
            _ = Darwin.kill(-processGroupIdentifier, SIGKILL)
        } else {
            _ = Darwin.kill(processIdentifier, SIGTERM)
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func processDidExit() {
        guard !finished else { return }

        // DispatchSource's exit event is delivered while the leader is still a
        // zombie, so the process group cannot have been reused yet. Signal the
        // group before waitpid reaps the leader and releases that identity.
        if let processGroupIdentifier, processGroupIdentifier > 1 {
            _ = Darwin.kill(-processGroupIdentifier, SIGTERM)
            _ = Darwin.kill(-processGroupIdentifier, SIGKILL)
        } else if let processIdentifier, processIdentifier > 1 {
            _ = Darwin.kill(processIdentifier, SIGTERM)
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }

        var status: Int32 = 0
        if let processIdentifier {
            while true {
                let result = waitpid(processIdentifier, &status, 0)
                if result == processIdentifier { break }
                if result == -1, errno == EINTR { continue }
                status = 0
                break
            }
        }
        finish(status: status)
    }

    private func finish(status: Int32?) {
        guard !finished else { return }
        finished = true
        timeoutSource?.cancel()
        timeoutSource = nil
        processExitSource?.cancel()
        processExitSource = nil
        processIdentifier = nil
        processGroupIdentifier = nil
        continuation?.yield(status ?? 0)
        continuation?.finish()
        continuation = nil
    }

    private func spawnProcess() -> (
        processIdentifier: pid_t,
        processGroupIdentifier: pid_t?
    )? {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let setupOK = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                path,
                O_RDONLY,
                0
            ) == 0
                && posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDOUT_FILENO,
                    path,
                    O_WRONLY,
                    0
                ) == 0
                && posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDERR_FILENO,
                    path,
                    O_WRONLY,
                    0
                ) == 0
        }
        guard setupOK else { return nil }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        let suspendedFlags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let groupedFlags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let groupEnabled: Bool
        if posix_spawnattr_setflags(&attributes, groupedFlags) == 0,
           posix_spawnattr_setpgroup(&attributes, 0) == 0 {
            groupEnabled = true
        } else {
            // Keep a single-process fallback if process-group setup is not
            // available on the host OS; the suspended lifecycle still closes
            // the race between spawn and exit-watcher installation.
            posix_spawnattr_destroy(&attributes)
            guard posix_spawnattr_init(&attributes) == 0 else { return nil }
            guard posix_spawnattr_setflags(&attributes, suspendedFlags) == 0 else {
                return nil
            }
            groupEnabled = false
        }

        let arguments = ["/bin/sh", "-c", command]
        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        let environmentArguments = mergedEnvironment.map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnStatus = Self.withCStringArray(arguments) { argv in
            Self.withCStringArray(environmentArguments) { envp in
                "/bin/sh".withCString { executable in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &fileActions,
                        &attributes,
                        argv,
                        envp
                    )
                }
            }
        }
        guard spawnStatus == 0, processIdentifier > 1 else { return nil }
        return (
            processIdentifier: processIdentifier,
            processGroupIdentifier: groupEnabled ? processIdentifier : nil
        )
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
