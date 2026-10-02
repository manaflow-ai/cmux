import Foundation

/// A typed local op the user made that its owner (the daemon) has not
/// settled yet. The store shows it on top of the confirmed mirror
/// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, "Clients are projections").
/// Applying an intent must be idempotent and conservation-safe: it never
/// adds or removes a tab, and it is a no-op when its tab or target is not
/// in the mirror.
public enum Intent: Sendable, Hashable {
    /// `move-tab`: `surface` into `pane` at final display `index`
    /// (`TabDragOutcome.strip`, a palette or keyboard move).
    case moveTab(surface: SurfaceID, toPane: PaneID, index: Int)
}

/// How an intent left the log. Each intent leaves exactly once.
public enum IntentSettlement: Sendable, Hashable {
    /// The daemon's echo of its transaction was applied.
    case echoed
    /// The store applied every event up to the intent's settle sequence
    /// (today the event sequence read after the command's reply; later the
    /// `request-settled` sequence of `mutation-echo-v1`).
    case applied
    /// The command failed.
    case rejected
}
