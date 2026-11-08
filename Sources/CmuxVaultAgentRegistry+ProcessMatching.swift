extension CmuxVaultAgentRegistry {
    /// Returns the most specific registration matching a live process.
    ///
    /// Registry construction seeds built-ins first and appends user and project config, so reverse
    /// matching lets an overlapping configured detector override a built-in without agent-specific
    /// branches in the scanner.
    func matchingRegistration(for process: VaultObservedAgentProcess) -> CmuxVaultAgentRegistration? {
        registrations.reversed().first { $0.detect.matches(process) }
    }
}
