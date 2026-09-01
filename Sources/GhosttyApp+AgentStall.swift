import Foundation

extension GhosttyApp {
    /// Shared PTY-output demand flags for the managed-agent stall supervisor.
    ///
    /// The object contains only a lock-protected descriptor table and is safe
    /// to consult from libghostty's serialized read callback.
    @MainActor
    static var agentStallOutputDemand: AgentStallOutputDemand? {
        // Alternate compositions (package tests and early app startup) may
        // install a different byte-tee bridge.  Stall supervision must simply
        // remain inactive there; a diagnostic path must never bring down the
        // terminal host with a composition precondition.
        return (terminalSurfaceRuntimeDependencies.byteTee as? TerminalOutputByteTeeBridge)?
            .agentStallOutputDemand
    }
}
