import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Flushes bytes that were typed while a managed SSH PTY was detached.
    ///
    /// This is an internal helper invoked by the generated retry wrapper while
    /// it temporarily owns terminal input. It intentionally does not resolve a
    /// cmux socket or print output.
    func runSSHPTYFlushInput(commandArgs: [String]) throws {
        guard commandArgs.isEmpty else { return }
        guard SSHPTYTerminalInputMode.flushInput() else {
            throw CLIError(
                message: String(
                    localized: "cli.sshPtyAttach.terminalInputFlushFailed",
                    defaultValue: "SSH terminal input could not be reset; reconnecting.",
                    bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
                ),
                exitCode: SSHPTYAttachExitCode.retryableTransient
            )
        }
    }
}
