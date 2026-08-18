import Darwin

extension CMUXCLI {
    /// Flushes bytes that were typed while a managed SSH PTY was detached.
    ///
    /// This is an internal helper invoked by the generated retry wrapper while
    /// it temporarily owns terminal input. It intentionally does not resolve a
    /// cmux socket or print output.
    func runSSHPTYFlushInput(commandArgs: [String]) {
        guard commandArgs.isEmpty else { return }
        SSHPTYTerminalInputMode.flushInput()
    }
}
