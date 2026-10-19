public import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation
import Observation

/// Feeds the sidebar's session tree (`sidebar.sessionTree`, Claude desktop's Code tab) from data
/// the app already has: each workspace's agent chats (their acpmux sessions), acpmux's `spawnedBy`
/// on those sessions' lanes, and the pull request of each session folder's branch (`gh pr view`,
/// as the chat header's chip reads it). Off, it leaves `SidebarSessionTree.state` nil.
@MainActor
public final class SidebarSessionTreeFeed {
    public static let shared = SidebarSessionTreeFeed()

    private var task: Task<Void, Never>?
    private let pullRequests = SidebarPullRequestStore()

    /// What one pass reads: the tree, and the folders whose pull requests it shows.
    private nonisolated struct Pass: Equatable, Sendable {
        var state: SidebarSessionTreeState
        var folders: Set<String>
    }

    /// Follows the setting, the lanes and every machine's `workspaces` from now on. `localHost` is
    /// this Mac's `install:<id>`: the lanes are this Mac's acpmux sessions.
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel], localHost: String?,
                      lanes: AgentLaneStore = .shared, tree: SidebarSessionTree = .shared) {
        guard task == nil else { return }
        let pullRequests = pullRequests
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        task = Task {
            for await pass in ObservationStream({ () -> Pass? in
                guard DesignSettings.shared.sidebarSections.sessionTree else { return nil }
                return Self.pass(workspaces(), lanes: lanes.lanes, localHost: localHost,
                                 pullRequests: pullRequests.answers)
            }) {
                if tree.state != pass?.state { tree.state = pass?.state }
                if let pass { pullRequests.refresh(pass.folders) }
            }
        }
    }

    private static func pass(_ workspaces: [WorkspaceModel], lanes: [String: AgentActivityLane], localHost: String?,
                             pullRequests: [String: AgentPanePullRequest]) -> Pass {
        // Each workspace's acpmux sessions on this Mac (the lanes cover this Mac's acpmux only).
        var sessions: [SidebarWorkspaceID: [String]] = [:]
        var owner: [String: SidebarWorkspaceID] = [:]
        for workspace in workspaces {
            let id = SidebarWorkspaceID(workspace.id)
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                guard let ref = tab.agentSession, ref.host == localHost, let session = ref.session else { continue }
                sessions[id, default: []].append(session)
                owner[session] = owner[session] ?? id
            }
        }
        var state = SidebarSessionTreeState()
        var folders: Set<String> = []
        for (id, ids) in sessions {
            let shown = ids.compactMap { lanes[$0] }
            if let parent = shown.lazy.compactMap({ $0.spawnedBy.flatMap { owner[$0] } }).first(where: { $0 != id }) {
                state.parents[id] = parent
            }
            let cwds = Set(shown.compactMap(\.cwd))
            folders.formUnion(cwds)
            // One pull request per branch: sessions in one folder share it.
            var seen: Set<String> = []
            let statuses = cwds.sorted().compactMap { pullRequests[$0] }.filter { seen.insert($0.url).inserted }.compactMap(Self.status)
            state.pullRequests[id] = SidebarPullRequestBadge.combining(statuses)
        }
        return Pass(state: state, folders: folders)
    }

    /// The badge color of one pull request; nil for a closed one, which the badge leaves out.
    static func status(_ pullRequest: AgentPanePullRequest) -> SidebarPullRequestBadge.Status? {
        switch pullRequest.state {
        case "merged": .merged
        case "closed": nil
        case "draft": .attention
        default: pullRequest.mergeable == "conflicting" || pullRequest.checks.state == "failing" ? .attention : .passing
        }
    }
}

/// The pull request of each session folder's branch, for the sidebar's session tree: read with the
/// chat header's reader (two gh calls at a time, never prompting), at most once every five minutes
/// per folder, when the tree passes again (a lane or a workspace changed). Nothing else polls. The
/// chat header's chip shares those two calls, so the sidebar asks seldom and never stalls it.
@MainActor @Observable
final class SidebarPullRequestStore {
    /// By folder; a folder whose branch has no pull request has none.
    private(set) var answers: [String: AgentPanePullRequest] = [:]
    @ObservationIgnored private var asked: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private let reader: AgentChatPullRequestReader
    @ObservationIgnored private let freshness: Duration

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(300)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// Asks again for each of `folders` whose answer is missing or older than `freshness`.
    func refresh(_ folders: Set<String>) {
        for folder in folders where !asking.contains(folder) {
            if let at = asked[folder], ContinuousClock.now - at < freshness { continue }
            ask(folder)
        }
    }

    private func ask(_ folder: String) {
        asking.insert(folder)
        asked[folder] = .now
        let reader = reader
        // task-owner: one gh read per stale folder; its answer lands in `answers`.
        Task { [weak self] in
            let answer = await reader.read(in: folder)
            guard let self else { return }
            asking.remove(folder)
            if answers[folder] != answer { answers[folder] = answer }
        }
    }
}
