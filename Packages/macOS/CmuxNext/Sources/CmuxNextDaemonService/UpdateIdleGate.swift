import CmuxNextAgentPane
public import CmuxNextWindowRules
import CmuxUpdater
import CoreGraphics
public import Foundation

/// Update When Idle (`updates.installWhenIdle`, off by default; Leo, 2026-11-19: "when it's idle, it's able to ...
/// update automatically ... maybe even having it as an opt-in option would be pretty interesting"). The
/// updater's automatic-install hold asks ``hold(idleMinutes:lastInput:)`` once a second while a staged update
/// waits; the rule is Rust's (cmux-window-rules `update_idle`). This reads the facts only: the input time
/// first, and this Mac's agent turns and drafts only once the person has been away long enough, so a person
/// at the Mac costs no acpmux read.
@MainActor
public final class UpdateIdleGate {
    private let activity: UpdateAgentActivity
    private weak var daemon: DaemonService?
    private let newChatDrafts: @MainActor () -> Int?
    private let rules = WindowRules()

    /// - Parameter newChatDrafts: new chats' typed text the app keeps before they have a session; nil unknown.
    public init(activity: UpdateAgentActivity, daemon: DaemonService, newChatDrafts: @escaping @MainActor () -> Int?) {
        self.activity = activity
        self.daemon = daemon
        self.newChatDrafts = newChatDrafts
    }

    /// Why the staged update waits now (nil when it installs) and the away reading an install acts on. Away is
    /// leo-workspace `tools/host_presence.py`'s: input idle past the idle time OR the screen locked (Leo,
    /// 2026-11-22: the Mac should update while he is away from the keyboard). `lastInput` stands in for the
    /// Mac's input time (the update-idle harness: a fleet Mac has no person), and then the screen lock is not
    /// read, so a locked fleet Mac does not count as away over the harness's "input now".
    /// `declined`/`sinceDecline`: automatic installs declined in a row and seconds since the last (the backoff).
    public func hold(idleMinutes: Double, lastInput: Date? = nil, declined: Int = 0,
                     sinceDecline: Double? = nil) -> (hold: WindowRules.UpdateIdleHold?, away: String?) {
        let inputIdle = lastInput.map { Date().timeIntervalSince($0) } ?? DaemonService.secondsSinceInput()
        var facts = WindowRules.UpdateIdleFacts(enabled: true, idleMinutes: idleMinutes, inputIdleSeconds: inputIdle,
                                                screenLocked: lastInput == nil ? Self.screenLocked() : nil,
                                                declinedInstalls: declined, secondsSinceDecline: sinceDecline)
        // Away first: while the person is at the Mac nothing else is read.
        switch rules.updateIdleHold(facts) {
        case .notIdle?: return (.notIdle, nil)
        case .backoff?: return (.backoff, nil)
        default: break
        }
        guard let daemon else { return (.unknown, nil) }
        let blockers = activity.applying(to: daemon.currentRelaunchBlockers(quietInput: nil))
        if let agents = Self.agentFacts(census: activity.census, blockers: blockers, newChatDrafts: newChatDrafts()) {
            facts.runningTurns = agents.runningTurns
            facts.unsentDrafts = agents.unsentDrafts
        }
        return rules.updateIdleDecision(facts)
    }

    /// Whether this login session's screen is locked (`CGSSessionScreenIsLocked` in the current session's
    /// dictionary, what host_presence.py reads through `ioreg`); nil when the session cannot be read, which is
    /// never evidence of away. An unlocked session omits the key: false.
    nonisolated static func screenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// This Mac's agent turns and unsent drafts, nil when any of them is unknown (the rule then holds).
    /// The app's chats (the tab mirror) and every turn of this Mac's acpmux, the Chief's included, and every
    /// session whose background subagents or sub-sessions still work with no turn open: the relaunch's daemon
    /// handover restarts such an agent (`stale_host_respawn.rs`), which would end that work. Drafts and
    /// background work are facts only from an acpmux that serves them (`idleFactsKnown`): an older one omits
    /// both, which is unknown, not none.
    nonisolated static func agentFacts(census: AcpmuxSessionCensus?, blockers: UpdateRelaunchBlockers,
                                       newChatDrafts: Int?) -> (runningTurns: Int, unsentDrafts: Int)? {
        guard let census, census.idleFactsKnown, !blockers.daemonStateUnavailable, let newChatDrafts else { return nil }
        let turns = max(blockers.busyAgentCount, census.inTurn + (census.chiefInTurn ? 1 : 0) + census.workingBelow)
        return (turns, census.drafts + newChatDrafts)
    }
}
