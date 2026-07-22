extension TabManager {
    /// Routes every window's timer through the process-wide reconciliation owner.
    func reconcileAgentStatusesPeriodically() {
        TerminalController.shared.reconcileAgentStatusesPeriodically(triggering: self)
    }
}
