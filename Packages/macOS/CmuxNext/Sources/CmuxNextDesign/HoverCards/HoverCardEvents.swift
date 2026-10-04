public import Foundation

/// Keeps cards away while it lasts.
public nonisolated enum HoverSuppression: String, Hashable, Sendable, CaseIterable {
    case drag, scroll
}

/// Inputs of the hover card state machine.
public nonisolated enum HoverCardEvent: Hashable, Sendable {
    /// What is under the pointer now: after a pointer move (`moved` true), or
    /// after content moved under a still pointer (layout, scroll, column
    /// scroll, window move: `moved` false), from a fresh hit test.
    case hit(HoverTarget?, moved: Bool)
    /// The one-shot timer for `token` fired.
    case deadline(token: Int)
    case dismiss(HoverDismissal)
    case suppress(HoverSuppression)
    case unsuppress(HoverSuppression)
    /// The target is gone (tab closed, workspace removed, strip torn down).
    case targetRemoved(HoverTargetID)
    /// Show `target`'s card now, until a dismissal (Show Resource Usage).
    case pin(HoverTarget)
}

/// Outputs: what the coordinator does to the one card and the one timer.
public nonisolated enum HoverCardEffect: Hashable, Sendable {
    /// Arms the one timer for `token` (replacing any armed one).
    case schedule(token: Int, after: Duration)
    case cancelTimer
    /// Shows the card for `target`, or moves it there and updates it.
    /// `sliding`: the card was visible for another target and slides over.
    case show(HoverTarget, sliding: Bool)
    case hide
}
