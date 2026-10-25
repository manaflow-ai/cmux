import CMUXAgentLaunch
import Foundation

/// What cmux does about one Claude usage-limit report while `automation.claudeAccountAutoSwitch`
/// is on. Decided by ``ClaudeAccountAutoSwitchRequest/action(pane:exhaustedKeys:isTrusted:now:timeZone:homeDirectory:)``.
enum ClaudeAccountAutoSwitchAction: Equatable, Sendable {
    /// Nothing: the pane is gone, runs on another machine, or has no Claude session cmux knows.
    case ignore
    /// Record the account as exhausted. No other account is free, so the pane keeps its
    /// "Usage limit, resets …" status.
    case markExhaustedOnly(Exhaustion)
    /// Record the account as exhausted, then move the pane to `to`. `sendContinue` is true only
    /// when `to` already trusts the session's folder, so the resumed Claude cannot be sitting at
    /// a trust prompt.
    case switchAccount(to: ClaudeAccount, sendContinue: Bool, exhausted: Exhaustion)

    /// The account that hit its usage limit and until when cmux skips it.
    struct Exhaustion: Equatable, Sendable {
        /// The account the pane ran under when it hit the limit.
        let account: ClaudeAccount
        /// The ``ClaudeAccountExhaustionStore`` key: the account's config directory.
        let accountKey: String
        /// When the limit resets: the time the limit message gave, or a conservative fallback.
        let until: Date
        /// The reset time the limit message gave; `nil` when it gave none and `until` is the
        /// fallback, which is a guess and never shown as a reset time.
        let quotedReset: Date?
    }

    /// The exhaustion every non-ignored action records.
    var exhaustion: Exhaustion? {
        switch self {
        case .ignore:
            return nil
        case .markExhaustedOnly(let exhaustion), .switchAccount(_, _, let exhaustion):
            return exhaustion
        }
    }
}
