import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation

/// Feeds the sidebar's session tree (`sidebar.sessionTree`, Claude desktop's Code tab) from data
/// the app already has: each workspace's agent chats (their acpmux sessions), acpmux's `spawnedBy`
/// on those sessions' lanes, the pull request of each session folder's branch (`gh pr view`, as the
/// chat header's chip reads it) and each pull request a session opened (acpmux `pullRequests`,
/// `gh pr view <url>`). Off, it leaves `SidebarSessionTree.state` nil.
@MainActor
final class SidebarSessionTreeFeed {
    static let shared = SidebarSessionTreeFeed()

    private var task: Task<Void, Never>?
    private let pullRequests = SidebarPullRequestStore()

    /// What one pass reads: the tree, and the folders and pull request URLs it shows.
    private nonisolated struct Pass: Equatable, Sendable {
        var state: SidebarSessionTreeState
        var asks: Set<String>
    }

    /// Follows the setting, the lanes and this Mac's workspaces from now on. `localHost` is this
    /// Mac's `install:<id>`: the lanes are this Mac's acpmux sessions.
    func start(_ services: AppServices, localHost: String?, lanes: AgentLaneStore = .shared, tree: SidebarSessionTree = .shared) {
        guard task == nil else { return }
        let pullRequests = pullRequests, machines = services.machines
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        task = Task {
            for await pass in ObservationStream({ () -> Pass? in
                guard DesignSettings.shared.sidebarSections.sessionTree else { return nil }
                return Self.pass(machines.allWorkspaces.map { $0.0 }, lanes: lanes.lanes, localHost: localHost,
                                 pullRequests: pullRequests.answers)
            }) {
                if tree.state != pass?.state { tree.state = pass?.state }
                if let pass { pullRequests.refresh(pass.asks) }
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
        var asks: Set<String> = []
        for (id, ids) in sessions {
            let shown = ids.compactMap { lanes[$0] }
            if let parent = shown.lazy.compactMap({ $0.spawnedBy.flatMap { owner[$0] } }).first(where: { $0 != id }) {
                state.parents[id] = parent
            }
            let wanted = Self.asks(shown)
            asks.formUnion(wanted)
            state.pullRequests[id] = Self.badge(wanted, answers: pullRequests)
        }
        return Pass(state: state, asks: asks)
    }

    /// What a workspace's sessions show: their folders (each one's branch's pull request) and the
    /// pull requests they opened (their URLs), as ``SidebarPullRequestStore`` keys them.
    static func asks(_ lanes: [AgentActivityLane]) -> [String] {
        let folders = Set(lanes.compactMap(\.cwd)).sorted()
        var opened: [String] = []
        for url in lanes.flatMap(\.pullRequests) where !opened.contains(url) { opened.append(url) }
        return folders + opened
    }

    /// The badge of `asks`' answers: each pull request once, though a folder's branch's and an
    /// opened one's URL, or two sessions in one folder, name the same.
    static func badge(_ asks: [String], answers: [String: AgentPanePullRequest]) -> SidebarPullRequestBadge? {
        var seen: Set<String> = []
        let statuses = asks.compactMap { answers[$0] }.filter { seen.insert($0.url).inserted }.compactMap(Self.status)
        return SidebarPullRequestBadge.combining(statuses)
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

/// The pull request of each session folder's branch and of each pull request URL a session opened,
/// for the sidebar's session tree: read with the chat header's reader (two gh calls at a time, never
/// prompting), at most once a minute per folder or URL, when the tree passes again (a lane or a
/// workspace changed). Nothing else polls.
@MainActor @Observable
final class SidebarPullRequestStore {
    /// By folder or URL; a folder whose branch has no pull request has none.
    private(set) var answers: [String: AgentPanePullRequest] = [:]
    @ObservationIgnored private var asked: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private let reader: AgentChatPullRequestReader
    @ObservationIgnored private let freshness: Duration

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(60)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// Asks again for each of `asks` (a folder, or a pull request's `https://` URL) whose answer is
    /// missing or older than `freshness`.
    func refresh(_ asks: Set<String>) {
        for key in asks where !asking.contains(key) {
            if let at = asked[key], ContinuousClock.now - at < freshness { continue }
            ask(key)
        }
    }

    private func ask(_ key: String) {
        asking.insert(key)
        asked[key] = .now
        let reader = reader
        // task-owner: one gh read per stale folder or URL; its answer lands in `answers`.
        Task { [weak self] in
            let answer = if key.hasPrefix("https://") { await reader.read(url: key) } else { await reader.read(in: key) }
            guard let self else { return }
            asking.remove(key)
            if answers[key] != answer { answers[key] = answer }
        }
    }
}
