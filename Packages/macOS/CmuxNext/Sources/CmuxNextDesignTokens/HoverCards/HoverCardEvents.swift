public import Foundation

/// Keeps cards away while it lasts.
public nonisolated enum HoverSuppression: String, Hashable, Sendable, CaseIterable {
    case drag, scroll, sidebarHide
}

/// Inputs of the hover card state machine.
public nonisolated enum HoverCardEvent: Hashable, Sendable {
    /// What is under the pointer now: after a pointer move (`moved` true), or
    /// after content moved under a still pointer (layout, scroll, column
    /// scroll, window move: `moved` false), from a fresh hit test.
    /// `aiming`: the pointer moved toward the shown card (or onto it, where
    /// it hits no target), along the safe triangle (`CGRect.isAimedAt`).
    /// `bridging`: no target, but the pointer is between a source's targets
    /// (a gap in a tab strip, a tab with no card) or on the shown card: a
    /// `hides` card stays for its reshow window (on the card, while the
    /// pointer rests there), so the next target swaps it in without a hide.
    case hit(HoverTarget?, moved: Bool, aiming: Bool = false, bridging: Bool = false)
    /// Whether the pointer rests on the shown card now (sent before each
    /// deadline: the card ignores the mouse, so no source sees it there).
    case pointerOnCard(Bool)
    /// The one-shot timer for `token` fired.
    case deadline(token: Int)
    case dismiss(HoverDismissal)
    case suppress(HoverSuppression)
    case unsuppress(HoverSuppression)
    /// The target is gone (tab closed, workspace removed, strip torn down).
    case targetRemoved(HoverTargetID)
    /// Show `target`'s card now, until a dismissal (Show Resource Usage).
    case pin(HoverTarget)
    /// A card its owner shows (the sidebar's Update Ready highlights) took the one card window
    /// (true), or left it (false). Taking it ends any pending or shown card without a hide (the
    /// one card morphs to the owner's content); while it shows, the next target the pointer
    /// reaches takes the card back at once, with no hover delay.
    case owned(Bool)
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
