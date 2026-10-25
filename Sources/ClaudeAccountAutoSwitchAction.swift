import CMUXAgentLaunch
import Foundation

/// What cmux does about one Claude usage-limit report while `automation.claudeAccountAutoSwitch`
/// is on. Decided by ``ClaudeAccountAutoSwitchRequest/action(pane:isEnabled:storedExhaustion:ledger:isUsable:isTrusted:now:timeZone:homeDirectory:)``.
enum ClaudeAccountAutoSwitchAction: Equatable, Sendable {
    /// Nothing: the setting went off, the pane is gone, runs on another machine, is already
    /// switching, has no Claude session cmux knows, or the report predates its last switch.
    case ignore
    /// Record the account as exhausted. No other account is free, so the pane keeps its
    /// "Usage limit, resets …" status.
    case markExhaustedOnly(Exhaustion)
    /// Record the account as exhausted, but leave the pane alone and tell the user why.
    case holdBack(Exhaustion, HoldBack)
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

    /// Why another account was free but the pane was not switched.
    enum HoldBack: Equatable, Sendable {
        /// The pane received input after the limit: someone is using it.
        case userInput
        /// The stopped turn left background work running, which a restart would kill.
        case backgroundWork
        /// The pane already went through every other account without finishing a turn.
        case attemptLimit
        /// The limit could not be written to the exhaustion file, so a later report could pick
        /// this account again.
        case notRecorded
    }

    /// The exhaustion every non-ignored action records.
    var exhaustion: Exhaustion? {
        switch self {
        case .ignore:
            return nil
        case .markExhaustedOnly(let exhaustion), .holdBack(let exhaustion, _), .switchAccount(_, _, let exhaustion):
            return exhaustion
        }
    }

    /// This action once the exhaustion was (or failed to be) written: a switch whose source
    /// account could not be recorded is held back.
    func recording(succeeded: Bool) -> ClaudeAccountAutoSwitchAction {
        guard !succeeded, case .switchAccount(_, _, let exhaustion) = self else { return self }
        return .holdBack(exhaustion, .notRecorded)
    }
}
