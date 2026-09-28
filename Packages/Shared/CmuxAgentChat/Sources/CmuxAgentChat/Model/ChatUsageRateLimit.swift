import Foundation

/// How much of a provider's usage allowance a session has consumed.
///
/// Codex writes this into its rollout on every token count. Claude Code
/// does not put limit state in its transcript at all, so this stays `nil`
/// for Claude sessions; the absence is the honest answer rather than a
/// zero.
public struct ChatUsageRateLimit: Sendable, Equatable {
    /// The short window, the one that throttles a burst of work.
    public var primary: Window

    /// The long window, when the provider reports one.
    ///
    /// Codex sends two windows: a roughly five-hour `primary` and a weekly
    /// `secondary`. The weekly one is usually what actually stops a day of
    /// work, and it is the one a session hits without warning, so dropping
    /// it would hide the limit that matters.
    public var secondary: Window?

    /// Whether the provider says a spend control has already cut the
    /// session off.
    public var spendControlReached: Bool

    /// Percentage of the ``primary`` window's allowance used.
    public var usedPercent: Double {
        get { primary.usedPercent }
        set { primary.usedPercent = newValue }
    }

    /// Length of the ``primary`` window in minutes.
    public var windowMinutes: Int? {
        get { primary.windowMinutes }
        set { primary.windowMinutes = newValue }
    }

    /// When the ``primary`` window resets.
    public var resetsAt: Date? {
        get { primary.resetsAt }
        set { primary.resetsAt = newValue }
    }

    /// Whichever reported window is closest to its limit.
    ///
    /// This is what a caller showing one number should show. Picking the
    /// primary window instead reads "12% used" on a session that is at 96%
    /// of its weekly allowance.
    public var tightestWindow: Window {
        guard let secondary, secondary.usedPercent > primary.usedPercent else {
            return primary
        }
        return secondary
    }

    /// Creates a rate limit reading from its windows.
    ///
    /// - Parameters:
    ///   - primary: The short window.
    ///   - secondary: The long window, when reported.
    ///   - spendControlReached: Whether a spend control has cut the session off.
    public init(primary: Window, secondary: Window? = nil, spendControlReached: Bool = false) {
        self.primary = primary
        self.secondary = secondary
        self.spendControlReached = spendControlReached
    }

    /// Creates a rate limit reading with only a primary window.
    ///
    /// - Parameters:
    ///   - usedPercent: Percentage of the allowance used.
    ///   - windowMinutes: Window length in minutes.
    ///   - resetsAt: When the window resets.
    public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.init(
            primary: Window(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt
            )
        )
    }
}
