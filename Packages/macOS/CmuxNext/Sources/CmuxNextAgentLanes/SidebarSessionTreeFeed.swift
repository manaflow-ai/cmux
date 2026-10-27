public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation

/// Feeds the sidebar's session tree (`sidebar.sessionTree`, Claude desktop's Code tab) from data
/// the app already has: each workspace's agent chats (their acpmux sessions), acpmux's `spawnedBy`
/// on those sessions' lanes, the parents another machine's daemon listed for the chats a chat there
/// started (``RemoteAgentSessionLinks``, a Cloud VM chat's children), the pull request of each session folder's branch (`gh pr view`, as the
/// chat header's chip reads it) and each pull request a session opened (acpmux `pullRequests`,
/// `gh pr view <url>`). Off, it leaves `SidebarSessionTree.state` nil. The pull request reads also
/// run while only the Priority view is on (`sidebar.priorityView.enabled`), for its Red CI
/// (``checksFailing(_:)``); the tree then stays off.
@MainActor
public final class SidebarSessionTreeFeed {
    public static let shared = SidebarSessionTreeFeed()

    private var task: Task<Void, Never>?
    /// Also read by ``checksFailing(_:)``, the Priority view's Red CI.
    let pullRequests = SidebarPullRequestStore()

    /// What one pass reads: the tree, and the folders and pull request URLs it shows.
    nonisolated struct Pass: Equatable, Sendable {
        var state: SidebarSessionTreeState
        var asks: Set<String>
        /// The session tree is on (`sidebar.sessionTree`): the pass writes `SidebarSessionTree.state`.
        /// Off, the pass runs only for the pull request badges and the Priority view's Red CI.
        var showsTree = true
    }

    /// Follows the setting, the lanes and every machine's `workspaces` from now on. `localHost` is
    /// this Mac's `install:<id>`: the lanes are this Mac's acpmux sessions.
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel], localHost: String?,
                      lanes: AgentLaneStore = .shared, remote: RemoteAgentSessionLinks = .shared,
                      tree: SidebarSessionTree = .shared) {
        guard task == nil else { return }
        let pullRequests = pullRequests
        let fixture = SidebarPullRequestFixture.enabled
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        task = Task {
            for await pass in ObservationStream({ () -> Pass? in
                let sections = DesignSettings.shared.sidebarSections
                guard Self.readsPullRequests(sections) || Self.readsBadges(sections) else { return nil }
                // Each local session's links only (`AgentLaneStore.links(_:)`): an agent's new step or state passes nothing
                // again; with the badges on this pass ran over every workspace on every agent event.
                let models = workspaces()
                let chats = Self.chats(models)
                var links: [String: AgentLaneLinks] = [:]
                for (_, refs) in chats {
                    for ref in refs where ref.host == localHost {
                        if let session = ref.session, let link = lanes.links(session) { links[session] = link }
                    }
                }
                var pass = Self.pass(chats, links: links, remoteParents: remote.parents, localHost: localHost,
                                     pullRequests: pullRequests.answers)
                pass.showsTree = sections.sessionTree
                // Captures: sample pull requests on every row, and no GitHub reads.
                if fixture { (pass.state.pullRequests, pass.asks) = (SidebarPullRequestFixture.badges(models), []) }
                return pass
            }) {
                Self.publish(pass, to: tree)
                if let pass, !fixture { pullRequests.refresh(pass.asks) } else { pullRequests.stop() }
            }
        }
    }

    /// `pass` into `tree`: the badges whenever the feed runs, the tree itself only while it shows.
    static func publish(_ pass: Pass?, to tree: SidebarSessionTree) {
        let state = pass?.showsTree == true ? pass?.state : nil
        if tree.state != state { tree.state = state }
        let badges = pass?.state.pullRequests ?? [:]
        if tree.pullRequests != badges { tree.pullRequests = badges }
    }

    /// Each workspace's agent chat tabs, in model order.
    static func chats(_ workspaces: [WorkspaceModel]) -> [(SidebarWorkspaceID, [AgentSessionRef])] {
        workspaces.map { workspace in
            (SidebarWorkspaceID(workspace.id), workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(\.agentSession))
        }
    }

    static func pass(_ chats: [(SidebarWorkspaceID, [AgentSessionRef])], lanes: [String: AgentActivityLane],
                     remoteParents: [String: String] = [:], localHost: String?,
                     pullRequests: [String: AgentPanePullRequest]) -> Pass {
        pass(chats, links: lanes.mapValues(AgentLaneLinks.init), remoteParents: remoteParents, localHost: localHost, pullRequests: pullRequests)
    }

    /// The pass over each session's links (`AgentLaneLinks`): all it reads of a lane.
    static func pass(_ chats: [(SidebarWorkspaceID, [AgentSessionRef])], links lanes: [String: AgentLaneLinks],
                     remoteParents: [String: String] = [:], localHost: String?,
                     pullRequests: [String: AgentPanePullRequest]) -> Pass {
        // Each workspace's acpmux sessions on this Mac (the lanes cover this Mac's acpmux only), and
        // its chats on other machines whose parent that machine's daemon listed.
        var sessions: [SidebarWorkspaceID: [String]] = [:]
        var remote: [SidebarWorkspaceID: [String]] = [:]
        var owner: [String: SidebarWorkspaceID] = [:]
        for (id, refs) in chats {
            for ref in refs {
                guard let session = ref.session else { continue }
                if ref.host == localHost { sessions[id, default: []].append(session) } else { remote[id, default: []].append(session) }
                owner[session] = owner[session] ?? id
            }
        }
        var state = SidebarSessionTreeState()
        var agentStates: [SidebarWorkspaceID: SidebarAgentState] = [:]
        var asks: Set<String> = []
        for (id, ids) in remote {
            if let parent = ids.lazy.compactMap({ remoteParents[$0].flatMap { owner[$0] } }).first(where: { $0 != id }) {
                state.parents[id] = parent
            }
        }
        for (id, ids) in sessions {
            let shown = ids.compactMap { lanes[$0] }
            if let parent = shown.lazy.compactMap({ $0.spawnedBy.flatMap { owner[$0] } }).first(where: { $0 != id }) {
                state.parents[id] = parent
            }
            // The strongest of its agents' states: one waiting on you outranks one still running.
            if let state = shown.map({ Self.state($0.state) }).max() { agentStates[id] = state }
            let wanted = Self.asks(links: shown)
            asks.formUnion(wanted)
            state.pullRequests[id] = Self.badge(wanted, answers: pullRequests)
        }
        state.states = agentStates
        return Pass(state: state, asks: asks)
    }

    /// What a workspace's sessions show: their folders (each one's branch's pull request) and the
    /// pull requests they opened (their URLs), as ``SidebarPullRequestStore`` keys them.
    static func asks(_ lanes: [AgentActivityLane]) -> [String] { asks(links: lanes.map(AgentLaneLinks.init)) }

    static func asks(links lanes: [AgentLaneLinks]) -> [String] {
        let folders = Set(lanes.compactMap(\.cwd)).sorted()
        var opened: [String] = []
        for url in lanes.flatMap(\.pullRequests) where !opened.contains(url) { opened.append(url) }
        return folders + opened
    }

    /// The badge of `asks`' answers, with each one's line for the hover card: each pull request
    /// once, though a folder's branch's and an opened one's URL, or two sessions in one folder,
    /// name the same.
    static func badge(_ asks: [String], answers: [String: AgentPanePullRequest]) -> SidebarPullRequestBadge? {
        var seen: Set<String> = []
        let items = asks.compactMap { answers[$0] }.filter { seen.insert($0.url).inserted }.map(Self.item)
        return SidebarPullRequestBadge.combining(items: items)
    }

    /// A lane's state in the tree's terms: acpmux's `input` waits on the person; a lost agent counts as failed.
    static func state(_ lane: AgentActivityLane.State) -> SidebarAgentState {
        switch lane {
        case .input: .blocked
        case .failed, .lost: .failed
        case .working: .running
        case .idle: .idle
        }
    }

    /// The badge color of one pull request; nil for a closed one, which the badge leaves out.
    static func status(_ pullRequest: AgentPanePullRequest) -> SidebarPullRequestBadge.Status? {
        item(pullRequest).state.badgeStatus
    }

    /// One pull request's line in the hover card. Failed checks say so before a conflict (red wins
    /// over orange); a pending check reads as passing until it fails.
    static func item(_ pullRequest: AgentPanePullRequest) -> SidebarPullRequestItem {
        let state: SidebarPullRequestItem.State = switch pullRequest.state {
        case "merged": .merged
        case "closed": .closed
        case "draft": .draft
        default: pullRequest.checks.state == "failing" ? .failing : pullRequest.mergeable == "conflicting" ? .conflict : .passing
        }
        return SidebarPullRequestItem(url: pullRequest.url, repository: SidebarPullRequestItem.repository(of: pullRequest.url),
                                      number: pullRequest.number, title: pullRequest.title, state: state,
                                      additions: pullRequest.additions, deletions: pullRequest.deletions,
                                      createdAt: pullRequest.createdAt)
    }
}

/// The pull request of each session folder's branch and of each pull request URL a session opened,
/// for the sidebar's session tree: read with the chat header's reader (two gh calls at a time, never
/// prompting), at most once every five minutes per folder or URL: when the tree passes again (a
/// lane or a workspace changed), and once every five minutes on its own while the tree shows
/// open pull requests (an idle session's CI can still fail). A folder is one `gh pr view` there; every stale github.com URL
/// goes in one batched GraphQL read (`read(urls:)`), never one call per pull request; a failed read
/// keeps the last answers. The
/// chat header's chip shares those two calls, so the sidebar asks seldom and never stalls it.
@MainActor @Observable
final class SidebarPullRequestStore {
    /// By folder or URL; a folder whose branch has no pull request has none.
    private(set) var answers: [String: AgentPanePullRequest] = [:]
    @ObservationIgnored private var asked: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    /// Failed reads in a row, by URL: each doubles its wait, up to ``maximumBackoff``.
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// The most doublings of `freshness` a failing URL waits (5 minutes become 80).
    static let maximumBackoff = 4
    @ObservationIgnored private let reader: AgentChatPullRequestReader
    /// What the tree showed last, read again by ``recheck``.
    @ObservationIgnored private var shown: Set<String> = []
    /// Reads `shown` again once `freshness` passes, though nothing in the tree changed.
    @ObservationIgnored private let recheck = DemandTimer(owner: "sidebar.pullRequests.recheck")
    @ObservationIgnored private let freshness: Duration

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(300)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// Asks again for each of `asks` (a folder, or a pull request's `https://` URL) whose answer is
    /// missing or older than `freshness`.
    func refresh(_ asks: Set<String>) {
        refresh(asks, onlyInFlight: false)
    }

    /// `onlyInFlight` is the recheck: it reads again only the open or draft pull requests, since a
    /// folder without one or a merged or closed one changes only with a lane or a workspace.
    private func refresh(_ asks: Set<String>, onlyInFlight: Bool) {
        shown = asks
        // Drop what the tree no longer shows (closed workspaces, ended sessions).
        let kept = asks.union(asking)
        let pruned = answers.filter { kept.contains($0.key) }
        if pruned.count != answers.count { answers = pruned } // a set always notifies the tree's observation
        asked = asked.filter { kept.contains($0.key) }
        failures = failures.filter { kept.contains($0.key) }
        scheduleRecheck()
        let stale = asks.filter { key in
            !asking.contains(key) && !isSettled(key) && (!onlyInFlight || inFlight(key)) && asked[key].map { ContinuousClock.now - $0 >= wait(key) } ?? true
        }
        let urls = stale.filter { $0.hasPrefix("https://") }.sorted()
        for folder in stale.subtracting(urls).sorted() { ask(folder) }
        if !urls.isEmpty { ask(urls: urls) }
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
            scheduleRecheck()
        }
    }

    private func ask(urls: [String]) {
        asking.formUnion(urls)
        for url in urls { asked[url] = .now }
        let reader = reader
        // task-owner: one batched gh read for every stale URL; the answers land in `answers`.
        Task { [weak self] in
            let read = await reader.read(urls: urls)
            guard let self else { return }
            asking.subtract(urls)
            // A URL whose read failed keeps its last answer and waits longer; one GitHub has no pull
            // request for clears.
            for url in urls {
                guard let answer = read[url] else {
                    failures[url, default: 0] += 1
                    continue
                }
                failures[url] = nil
                if answers[url] != answer { answers[url] = answer }
            }
            scheduleRecheck()
        }
    }

    /// Keeps the recheck pending while the tree shows an open or draft pull request, else stops it.
    /// It runs on every refresh and again when an answer lands: the first answer is what makes a
    /// shown pull request open, and the store reads it again then without waiting for the tree.
    private func scheduleRecheck() {
        if freshness > .zero, shown.contains(where: inFlight) {
            recheck.scheduleIfIdle(after: freshness) { @MainActor [weak self] in
                guard let self else { return }
                refresh(shown, onlyInFlight: true)
            }
        } else {
            recheck.cancel()
        }
    }

    /// Whether the five-minute recheck is pending.
    var rechecks: Bool { recheck.isScheduled }

    /// Stops the recheck: the tree is off.
    func stop() {
        shown = []
        recheck.cancel()
    }

    /// A merged pull request's URL: it never changes again, so it is not asked again. (A closed one
    /// can be reopened; a folder's branch can get a new pull request after one merges, so both are.)
    func isSettled(_ key: String) -> Bool {
        key.hasPrefix("https://") && answers[key]?.state == "merged"
    }

    /// A shown pull request whose CI or review can still change on its own (open or draft): what
    /// keeps the five-minute recheck. A folder without one, or a merged or closed one, changes only
    /// with a lane or a workspace, which passes the tree again anyway.
    func inFlight(_ key: String) -> Bool {
        guard let state = answers[key]?.state else { return false }
        return state != "merged" && state != "closed"
    }

    /// How long `key`'s answer stays fresh: `freshness`, doubled for each failed read in a row.
    func wait(_ key: String) -> Duration {
        freshness * (1 << min(failures[key] ?? 0, Self.maximumBackoff))
    }
}
