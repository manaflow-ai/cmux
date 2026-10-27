/// Hears the end of every outermost perform turn of an ``ActionRegistry``: the turn in which
/// ``ActionRegistry/perform(_:invocation:)`` ran the action (or refused it) and returned, before
/// any remote half of its effect replies. The refactor oracle records its `turn` checkpoint here
/// (plans/cmux-next/chrome-parity/p15-oracle.md, task 032 and invariant I3: what the person sees
/// on the turn must equal the settled state, or the settled state must be a refusal).
///
/// The registry takes one at init and never changes it (``ActionRegistry/turnObserver``): the App's
/// composition root passes the oracle recorder in DEV and bench builds and nil in Release, so a
/// Release perform pays one nil check. A perform nested in a handler is part of its outer turn
/// and is not reported on its own.
@MainActor
public protocol ActionRunObserver: AnyObject {
    /// Called once at the end of an outermost perform turn, on the main actor.
    ///
    /// - Parameter turn: The action, who started it, and whether it ran.
    func performTurnEnded(_ turn: ActionTurn)
}

/// One perform turn as an ``ActionRunObserver`` hears it.
public nonisolated struct ActionTurn: Sendable, Hashable {
    /// The canonical id of the performed action.
    public let id: ActionID
    /// Who started the run.
    public let origin: ActionOrigin
    /// What ``ActionRegistry/perform(_:invocation:)`` returned: false for a refused run (disabled
    /// feature, unavailable, disabled, refused target), true for a run, a gate or a key window's route.
    public let ran: Bool

    public init(id: ActionID, origin: ActionOrigin, ran: Bool) {
        self.id = id
        self.origin = origin
        self.ran = ran
    }
}
