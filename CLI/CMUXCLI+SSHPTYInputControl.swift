import Foundation

extension CMUXCLI {
    /// A tty that cannot be protected must never fall back to cooked forwarding.
    func sshPTYTerminalModeError() -> CLIError {
        CLIError(message: String(
            localized: "cli.sshPtyAttach.terminalModeFailed",
            defaultValue: "SSH attach stopped because terminal input could not be placed in raw forwarding mode. Reconnect the workspace to try again.",
            bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        ))
    }

    /// Flushes bytes typed while a managed persistent SSH PTY was detached.
    ///
    /// The generated retry wrapper invokes this internal no-socket command
    /// while it owns terminal input between attachment attempts.
    func runSSHPTYFlushInput(commandArgs: [String]) throws {
        let bundle = CLIExecutableLocator.enclosingAppBundle() ?? .main
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
        guard SSHPTYTerminalInputMode.flushInput() else {
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
