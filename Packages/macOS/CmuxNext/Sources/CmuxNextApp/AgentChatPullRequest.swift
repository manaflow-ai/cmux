import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Observation

/// The chat header's pull request chip, per chat (cx-tcwj): the header state reads ``badge(cwd:)``
/// while its watch observes it, so the answer is pushed to the page when it lands. A folder is
/// asked again when the header is read after its answer is older than `freshness`, and on its own
/// after `freshness` while its checks run, so the dot turns when they finish; nothing else polls.
@MainActor @Observable
final class AgentChatPullRequest {
    private struct Answer {
        var cwd: String
        var badge: AgentPanePullRequest?
        var at: ContinuousClock.Instant
    }

    private var answer: Answer?
    @ObservationIgnored private let reader: AgentChatPullRequestReader
    @ObservationIgnored private let freshness: Duration
    /// The folder being asked now.
    @ObservationIgnored private var asking: String?
    /// A turn ended while that ask ran: its answer may predate the agent's push, so ask once more.
    @ObservationIgnored private var askAfter = false
    /// Asks again while the answer's checks run.
    @ObservationIgnored private let refresh = DemandTimer(owner: "header-pull-request-checks")

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(60)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// The pull request of `cwd`'s branch as last read (nil: none, or not read yet); asks again
    /// when there is no fresh answer for `cwd`.
    func badge(cwd: String?) -> AgentPanePullRequest? {
        guard let cwd else { return nil }
        let known = answer?.cwd == cwd ? answer : nil
        if asking != cwd, known.map({ ContinuousClock.now - $0.at > freshness }) ?? true { ask(cwd) }
        return known?.badge
    }

    /// Asks again for the folder last asked about, fresh or not: a turn ended, and the agent may
    /// have created the pull request or pushed to it (cx-mb1e0).
    func askAgain() {
        if asking != nil { askAfter = true } else if let cwd = answer?.cwd { ask(cwd) }
    }

    private func ask(_ cwd: String) {
        asking = cwd
        refresh.cancel()
        let reader = reader
        // task-owner: one gh read per stale folder; its answer lands on this chat's state.
        Task { [weak self] in
            let badge = await reader.read(in: cwd)
            guard let self, asking == cwd else { return }
            asking = nil
            answer = Answer(cwd: cwd, badge: badge, at: .now)
            if askAfter {
                askAfter = false
                return ask(cwd)
            }
            guard badge?.checks.state == "pending" else { return }
            refresh.schedule(after: freshness) { @MainActor [weak self] in
                guard let self, answer?.cwd == cwd, asking == nil else { return }
                ask(cwd)
            }
        }
    }
}
