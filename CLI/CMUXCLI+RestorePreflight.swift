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
            invocation.arguments[0],
            environment: invocationEnvironment
        ) else {
            throw CLIError(
                message: "restore: preflight executable "
                    + "'\(invocation.arguments[0])' was not found"
            )
        }
        var fileActions: posix_spawn_file_actions_t?
        let actionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard actionsStatus == 0 else {
            throw CLIError(
                message: "restore: could not configure provider preflight: "
                    + String(cString: strerror(actionsStatus))
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
        guard redirectStatus == 0 else {
            throw CLIError(
                message: "restore: could not configure provider preflight: "
                    + String(cString: strerror(redirectStatus))
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
                message: "restore: could not start preflight: "
                    + String(cString: strerror(status))
            )
        }
        try waitForRestorePreflight(processID, invocation: invocation)
    }

    private func waitForRestorePreflight(
        _ processID: pid_t,
        invocation: AgentRestorePreflightInvocation
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var waitStatus: Int32 = 0
        while true {
            let waitResult = waitpid(processID, &waitStatus, WNOHANG)
            if waitResult == processID {
                break
            }
            if waitResult == -1 {
                if errno == EINTR {
                    continue
                }
                throw CLIError(
                    message: "restore: could not wait for provider preflight: "
                        + String(cString: strerror(errno))
                )
            }
            if ContinuousClock.now >= deadline {
                terminateRestorePreflight(processID)
                throw CLIError(
                    message: "restore: provider preflight timed out after 10 seconds ("
                        + restorePreflightLabel(invocation)
                        + ")"
                )
            }
            usleep(10_000)
        }
        let exitedNormally = waitStatus & 0x7f == 0
        let exitStatus = (waitStatus >> 8) & 0xff
        guard exitedNormally, exitStatus == 0 else {
            throw CLIError(message: "restore: provider preflight failed")
        }
    }

    private func terminateRestorePreflight(_ processID: pid_t) {
        _ = kill(processID, SIGTERM)
        let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var waitStatus: Int32 = 0
        while ContinuousClock.now < graceDeadline {
            let waitResult = waitpid(processID, &waitStatus, WNOHANG)
            if waitResult == processID || (waitResult == -1 && errno == ECHILD) {
                return
            }
            if waitResult == -1 && errno != EINTR {
                break
            }
            usleep(10_000)
        }

        _ = kill(processID, SIGKILL)
        while true {
            let waitResult = waitpid(processID, &waitStatus, 0)
            if waitResult == processID || (waitResult == -1 && errno == ECHILD) {
                return
            }
            if waitResult == -1 && errno == EINTR {
                continue
            }
            return
        }
    }

    private func restorePreflightLabel(
        _ invocation: AgentRestorePreflightInvocation
    ) -> String {
        guard let executable = invocation.arguments.first else {
            return "provider setup"
        }
        let command = URL(fileURLWithPath: executable).lastPathComponent
        return ([command] + Array(invocation.arguments.dropFirst().dropLast()))
            .joined(separator: " ")
    }
}
