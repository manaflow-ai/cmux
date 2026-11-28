import Foundation

/// A provider snapshot of allowance windows and spend-control state.
///
/// Codex writes this into its rollout on every token count. Claude Code
/// does not put limit state in its transcript at all, so this stays `nil`
/// for Claude sessions; the absence is the honest answer rather than a
/// zero. Fields inside a Codex snapshot are independently optional too.
public struct ChatUsageRateLimit: Sendable, Equatable {
    /// The short window, when the provider reports it.
    public var primary: Window?

    /// The long window, when the provider reports one.
    ///
    /// Codex sends two windows: a roughly five-hour `primary` and a weekly
    /// `secondary`. The weekly one is usually what actually stops a day of
    /// work, and it is the one a session hits without warning, so dropping
    /// it would hide the limit that matters.
    public var secondary: Window?

    /// Whether the provider says a spend control has cut the session off.
    ///
    /// `nil` means the snapshot omitted the flag; it must not be presented
    /// as `false`, which would claim the control has not been reached.
    public var spendControlReached: Bool?

    /// Percentage of the ``primary`` window's allowance used.
    public var usedPercent: Double? {
        get { primary?.usedPercent }
        set {
            guard let newValue else {
                primary = nil
                return
            }
            if primary == nil {
                primary = Window(usedPercent: newValue)
            } else {
                primary?.usedPercent = newValue
            }
        }
    }

    /// Length of the ``primary`` window in minutes.
    public var windowMinutes: Int? {
        get { primary?.windowMinutes }
        set { primary?.windowMinutes = newValue }
    }

    /// When the ``primary`` window resets.
    public var resetsAt: Date? {
        get { primary?.resetsAt }
        set { primary?.resetsAt = newValue }
    }

    /// Whichever reported window is closest to its limit.
    ///
    /// This is what a caller showing one number should show. Picking the
    /// primary window instead reads "12% used" on a session that is at 96%
    /// of its weekly allowance.
    public var tightestWindow: Window? {
        switch (primary, secondary) {
        case let (primary?, secondary?):
            return secondary.usedPercent > primary.usedPercent ? secondary : primary
        case let (primary?, nil):
            return primary
        case let (nil, secondary?):
            return secondary
        case (nil, nil):
            return nil
        }
    }

    /// Creates a rate limit reading from its windows.
    ///
    /// - Parameters:
    ///   - primary: The short window, when reported.
    ///   - secondary: The long window, when reported.
    ///   - spendControlReached: Whether a spend control has cut the session off,
    ///     or `nil` when the snapshot omitted that state.
    public init(
        primary: Window? = nil,
        secondary: Window? = nil,
        spendControlReached: Bool? = nil
    ) {
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
