import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    func runRestorePreflight(
        _ invocation: AgentRestorePreflightInvocation,
        appliedWorkingDirectory: String?
    ) throws {
        var invocationEnvironment = invocation.environment
        if let appliedWorkingDirectory {
            invocationEnvironment["PWD"] = appliedWorkingDirectory
        }
        guard let executable = resolveRestoreExecutable(
            invocation.executable,
            environment: invocationEnvironment
        ) else {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.providerSetupUnavailable",
                    defaultValue: "restore: provider setup is unavailable"
                )
            )
        }
        var fileActions: posix_spawn_file_actions_t?
        let actionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard actionsStatus == 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.providerSetupConfigurationFailed",
                    defaultValue: "restore: could not configure provider setup"
                )
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var redirectStatus = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                $0,
                O_RDONLY,
                0
            )
        }
        if redirectStatus == 0 {
            redirectStatus = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDOUT_FILENO,
                    $0,
                    O_WRONLY,
                    0
                )
            }
        }
        if redirectStatus == 0 {
            redirectStatus = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDERR_FILENO,
                    $0,
                    O_WRONLY,
                    0
                )
            }
        }
        guard redirectStatus == 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.providerSetupConfigurationFailed",
                    defaultValue: "restore: could not configure provider setup"
                )
            )
        }

        var processID: pid_t = 0
        let status = withCStringArray(invocation.arguments) { argv in
            withEnvironmentCStringArray(invocationEnvironment) { environment in
                executable.withCString {
                    posix_spawn(
                        &processID,
                        $0,
                        &fileActions,
                        nil,
                        argv,
                        environment
                    )
                }
            }
        }
        guard status == 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.providerSetupStartFailed",
                    defaultValue: "restore: could not start provider setup"
                )
            )
        }
        try waitForRestorePreflight(processID)
    }

    private func waitForRestorePreflight(_ processID: pid_t) throws {
        // This synchronous CLI is about to call `execve`; EVFILT_PROC provides
        // signal-driven completion with a kernel-enforced deadline and no poll.
        let exitQueue = try restorePreflightExitQueue(processID)
        defer { close(exitQueue) }

        guard try waitForRestorePreflightExit(
            exitQueue,
            timeout: 10
        ) else {
            terminateRestorePreflight(processID, exitQueue: exitQueue)
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.providerSetupTimedOut",
                    defaultValue: "restore: provider setup timed out after 10 seconds"
                )
            )
        }

        let waitStatus = try reapRestorePreflight(processID)
        let exitedNormally = waitStatus & 0x7f == 0
        let exitStatus = (waitStatus >> 8) & 0xff
        if exitedNormally {
            guard exitStatus == 0 else {
                throw CLIError(
                    message: String.localizedStringWithFormat(
                        String(
                            localized: "cli.restore.error.providerSetupExited",
                            defaultValue: "restore: provider setup failed with status %lld"
                        ),
                        Int64(exitStatus)
                    )
                )
            }
            return
        }
        let terminationSignal = waitStatus & 0x7f
        throw CLIError(
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.restore.error.providerSetupSignaled",
                    defaultValue: "restore: provider setup terminated by signal %lld"
                ),
                Int64(terminationSignal)
            )
        )
    }

    private func restorePreflightExitQueue(_ processID: pid_t) throws -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else {
            throw restorePreflightWaitError()
        }

        var event = kevent(
            ident: UInt(processID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        while kevent(queue, &event, 1, nil, 0, nil) != 0 {
            if errno == EINTR {
                continue
            }
            close(queue)
            throw restorePreflightWaitError()
        }
        return queue
    }

    private func waitForRestorePreflightExit(
        _ queue: Int32,
        timeout: TimeInterval
    ) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, &timeoutSpec)
            if result > 0 {
                return true
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                throw restorePreflightWaitError()
            }
        }
    }

    private func terminateRestorePreflight(
        _ processID: pid_t,
        exitQueue: Int32
    ) {
        _ = kill(processID, SIGTERM)
        var observedExit = (try? waitForRestorePreflightExit(
            exitQueue,
            timeout: 0.25
        )) == true
        if !observedExit {
            _ = kill(processID, SIGKILL)
            observedExit = (try? waitForRestorePreflightExit(
                exitQueue,
                timeout: 1
            )) == true
        }
        if observedExit {
            _ = try? reapRestorePreflight(processID)
        } else {
            _ = try? reapRestorePreflight(processID, options: WNOHANG)
        }
    }

    private func reapRestorePreflight(
        _ processID: pid_t,
        options: Int32 = 0
    ) throws -> Int32 {
        var waitStatus: Int32 = 0
        while true {
            let waitResult = waitpid(processID, &waitStatus, options)
            if waitResult == processID {
                return waitStatus
            }
            if waitResult == 0, options & WNOHANG != 0 {
                return waitStatus
            }
            if waitResult == -1 && errno == EINTR {
                continue
            }
            throw restorePreflightWaitError()
        }
    }

    private func restorePreflightWaitError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.restore.error.providerSetupWaitFailed",
                defaultValue: "restore: could not wait for provider setup"
            )
        )
    }
}
