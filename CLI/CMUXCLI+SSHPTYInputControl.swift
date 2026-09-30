import CmuxFoundation
import Darwin
import Foundation

extension CMUXCLI {
    /// Converts package admission into the CLI's localized diagnostic.
    func validateSSHPTYDaemonVersion(_ version: String?, clientVersion: String) throws {
#if DEBUG
        let allowsDevelopmentFingerprint = true
#else
        let allowsDevelopmentFingerprint = false
#endif
        guard SSHPTYDaemonCompatibility(
            clientVersion: clientVersion,
            allowsDevelopmentFingerprint: allowsDevelopmentFingerprint
        ).matches(version) else {
            throw CLIError(message: String(
                localized: "cli.sshPtyAttach.incompatibleDaemon",
                defaultValue: "SSH attach stopped because the remote daemon version does not match this cmux client. Install a cmux release with its matching remote daemon, then reconnect the workspace. Do not substitute a daemon from an older release.",
                bundle: CMUXCLILocalization.bundle
            ))
        }
    }

    /// Converts the observed signal into the conventional process exit status.
    func checkSSHPTYCancellation(_ monitor: SSHPTYAttachSignalMonitor?) throws {
        if let number = monitor?.cancellationSignal {
            throw CLIError(message: "", exitCode: 128 + number)
        }
    }

    /// A tty that cannot be protected must never fall back to cooked forwarding.
    func sshPTYTerminalModeError() -> CLIError {
        CLIError(message: String(
            localized: "cli.sshPtyAttach.terminalModeFailed",
            defaultValue: "SSH attach stopped because terminal input could not be placed in raw forwarding mode. Reconnect the workspace to try again.",
            bundle: CMUXCLILocalization.bundle
        ))
    }

    /// Flushes bytes typed while a managed persistent SSH PTY was detached.
    ///
    /// The generated retry wrapper invokes this internal no-socket command
    /// while it owns terminal input between attachment attempts.
    func runSSHPTYFlushInput(commandArgs: [String]) throws {
        let bundle = CMUXCLILocalization.bundle
        guard commandArgs.isEmpty else {
            throw CLIError(
                message: String(
                    localized: "cli.sshPtyAttach.flushInputUsage",
                    defaultValue: "Internal SSH input flush does not accept arguments.",
                    bundle: bundle
                ),
                exitCode: 2
            )
        }
        guard SSHPTYTerminalInputMode.flushInput(fileDescriptor: STDIN_FILENO) else {
            throw CLIError(
                message: String(
                    localized: "cli.sshPtyAttach.flushInputFailed",
                    defaultValue: "SSH terminal input could not be discarded safely.",
                    bundle: bundle
                )
            )
        }
    }
}
