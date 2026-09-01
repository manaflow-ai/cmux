import Foundation

extension CMUXCLI {
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
