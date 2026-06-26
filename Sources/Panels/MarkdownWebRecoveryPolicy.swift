/// Pure crash-recovery + detach/reattach budget state machine for the Markdown
/// WebContent shell.
///
/// Owns the WebContent-process recovery-attempt counter, its ceiling, and the
/// "was the shell healthy when the host view last left its window" flag, and
/// exposes the budget decisions the renderer coordinator forwards into. Holds
/// no WebKit or live view state: the `loadShell` effect and the `WKWebView`
/// identity guard stay in the coordinator.
struct MarkdownWebRecoveryPolicy: Sendable {
    /// WebContent-process recovery reloads attempted since the budget was last
    /// reset.
    private(set) var attempts: Int

    /// Maximum recovery reloads granted before the panel gives up.
    let maxAttempts: Int

    /// Whether the shell was confirmed loaded at the moment the host view last
    /// left its window. Used to distinguish a blank state caused by detaching
    /// the pane (WebKit suspending/reclaiming the detached view — recoverable)
    /// from one caused by a payload that keeps crashing WebContent while
    /// attached (a crash loop whose recovery budget must not be reset by pane
    /// reparenting).
    private(set) var shellWasHealthyWhenDetached: Bool

    init(maxAttempts: Int = 2) {
        self.attempts = 0
        self.maxAttempts = maxAttempts
        self.shellWasHealthyWhenDetached = false
    }

    /// Whether a further recovery reload is still within budget.
    var hasBudgetRemaining: Bool {
        attempts < maxAttempts
    }

    /// Fully clears the state machine (counter and detach flag), matching a
    /// web-view teardown.
    mutating func reset() {
        attempts = 0
        shellWasHealthyWhenDetached = false
    }

    /// Resets only the recovery budget, matching a content change.
    mutating func resetBudget() {
        attempts = 0
    }

    /// Consumes one unit of recovery budget. Returns `true` and increments the
    /// counter when budget remained, `false` when the budget is exhausted.
    mutating func consumeBudget() -> Bool {
        guard attempts < maxAttempts else { return false }
        attempts += 1
        return true
    }

    /// Records, at the moment the host view leaves its window, whether the
    /// document was healthy.
    mutating func recordDetachHealth(shellIsLoaded: Bool) {
        shellWasHealthyWhenDetached = shellIsLoaded
    }

    /// Grants a fresh recovery budget for a deliberate reattach, but only when
    /// the document was healthy before the detach, so a payload that exhausted
    /// its crash-recovery budget while attached (a crash loop) is not granted a
    /// fresh budget by pane reparenting. Returns `true` (proceed with a reload)
    /// only in that case, clearing the detach flag and restoring the budget.
    mutating func consumeDetachRecovery() -> Bool {
        guard shellWasHealthyWhenDetached else { return false }
        shellWasHealthyWhenDetached = false
        attempts = 0
        return true
    }
}
