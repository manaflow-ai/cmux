import Foundation

/// Scrollback budgets for `mobile.terminal.replay` render-grid snapshots.
enum MobileReplayScrollbackBudget {
    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    /// Live render-grid events carry no scrollback (the client already has it);
    /// only the replay anchor needs history. Kept minimal on purpose: a
    /// freshly-attached device gets the live screen immediately, and deeper
    /// history is a follow-up (the phone pages it in on scroll-to-top).
    /// Tune up to trade replay payload size for more attach-time history.
    static let attachLineBudget = 1

    /// Upper bound on the scrollback a single `mobile.terminal.replay` may
    /// carry when the phone requests a deeper-history fetch for local scrolling
    /// (Stage 1 smooth scroll). Bounds the replay payload so a hostile or
    /// runaway `scrollback_lines` request can't bloat one frame; the phone
    /// pages in chunks rather than asking for unbounded history.
    static let fetchLineBudgetMax = 2000

    /// Clamp a phone-requested deeper-history budget. Absent or invalid →
    /// the minimal attach-time budget.
    static func clamped(requested: Int?) -> Int {
        guard let requested else { return attachLineBudget }
        return max(attachLineBudget, min(requested, fetchLineBudgetMax))
    }
}
