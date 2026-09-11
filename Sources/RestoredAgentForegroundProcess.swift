import Foundation

/// Foreground-process evidence that a restored or hook-published agent is
/// still the command running in its pane.
///
/// Pi-compatible TUIs emit OSC 133 prompt and command marks while the agent
/// keeps running, so cmux's shell-activity state flips between idle and busy
/// on every turn. A flip alone cannot prove that the agent exited or was
/// replaced (#12084); the process in the pane's foreground can. This covers
/// the window before the agent's session-start hook has registered its PID
/// with cmux, when neither the runtime PID table nor the live agent index can
/// vouch for the session yet.
enum RestoredAgentForegroundProcess {
    /// Whether the pane's foreground process is `agent`'s own process.
    ///
    /// The foreground process must identify the session explicitly. Bare argv
    /// cannot distinguish a resumed Pi from a new Pi in the same pane. Current
    /// hook PID generations are validated by `RestoredAgentLiveness` first.
    static func matches(
        _ agent: SessionRestorableAgentSnapshot,
        foregroundProcessID: Int?,
        processArguments: (Int) -> CmuxTopProcessArguments? =
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:),
        validator: CachedAgentProcessIdentityValidator = CachedAgentProcessIdentityValidator()
    ) -> Bool {
        guard let foregroundProcessID,
              foregroundProcessID > 0,
              foregroundProcessID <= Int(Int32.max),
              let process = processArguments(foregroundProcessID) else {
            return false
        }
        return validator.currentProcess(
            process,
            matches: agent
        )
    }
}
