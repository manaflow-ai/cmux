import Foundation
import Observation

/// State shared by the three designs. A real app feeds it from the team's
/// Macs; the demo uses `WorkspacesStore.sample()`.
@MainActor
@Observable
public final class WorkspacesStore {
    public enum Phase: Sendable, Equatable {
        /// Cached rows are shown while Macs connect; never an empty state.
        case connecting
        case live
    }

    public private(set) var teams: [WorkspaceTeam]
    public var teamID: String
    public private(set) var workspaces: [WorkspaceItem]
    public var phase: Phase
    /// Where the pencil and the home prompt create new workspaces.
    public var newWorkspaceMacID: String
    public var now: Date

    public init(teams: [WorkspaceTeam], workspaces: [WorkspaceItem], phase: Phase = .live, now: Date = Date()) {
        self.teams = teams
        self.teamID = teams.first?.id ?? ""
        self.workspaces = workspaces
        self.phase = phase
        self.now = now
        self.newWorkspaceMacID = teams.first?.macs.first(where: \.isOnline)?.id ?? ""
    }

    public var team: WorkspaceTeam? { teams.first { $0.id == teamID } }
    public var macs: [WorkspaceMac] { team?.macs ?? [] }
    public var grouping: WorkspaceGrouping { WorkspaceGrouping(now: now) }
    public var needsYouCount: Int { workspaces.filter { $0.status.needsUser }.count }
    public var runningCount: Int { workspaces.filter { $0.status == .working }.count }

    public func mac(_ id: String) -> WorkspaceMac? { macs.first { $0.id == id } }
    public func workspace(_ id: String) -> WorkspaceItem? { workspaces.first { $0.id == id } }

    /// Needs-you workspaces other than `id` (the badge on Back).
    public func othersNeedingYou(besides id: String) -> Int {
        workspaces.filter { $0.id != id && $0.status.needsUser }.count
    }

    public func open(_ id: String) { update(id) { $0.unreadCount = 0 } }
    public func togglePin(_ id: String) { update(id) { $0.isPinned.toggle() } }
    public func markDone(_ id: String) { update(id) { $0.status = .done; $0.unreadCount = 0 } }
    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }
    public func close(_ id: String) { workspaces.removeAll { $0.id == id } }

    /// Answers a waiting permission prompt.
    public func resolvePrompt(_ id: String, allow: Bool) {
        update(id) { $0.status = allow ? .working : .idle; $0.unreadCount = 0 }
    }

    /// Creates a workspace instantly; with a prompt, Chief starts on it.
    @discardableResult
    public func create(on macID: String? = nil, prompt: String? = nil) -> WorkspaceItem {
        let mac = macID ?? newWorkspaceMacID
        newWorkspaceMacID = mac
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = text.isEmpty ? "New workspace" : String(text.prefix(40))
        let id = UUID().uuidString
        let item = WorkspaceItem(
            id: id, name: name, branch: "main", macID: mac, lastActivity: now,
            status: text.isEmpty ? .idle : .working, lastMessage: text.isEmpty ? "Ready." : "Reading the repository…",
            tabs: [WorkspaceTab(id: id + "-chief", kind: .chief, title: "Chief"), WorkspaceTab(id: id + "-zsh", kind: .terminal, title: "zsh")]
        )
        workspaces.insert(item, at: 0)
        return item
    }

    private func update(_ id: String, _ change: (inout WorkspaceItem) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaces[index])
    }
}

public extension WorkspacesStore {
    /// Example team and workspaces for previews and the demo app.
    static func sample(now: Date = Date()) -> WorkspacesStore {
        let macs = [
            WorkspaceMac(id: "studio", name: "Mac Studio", isOnline: true),
            WorkspaceMac(id: "mbp", name: "MacBook Pro", isOnline: true),
            WorkspaceMac(id: "mini", name: "mini-cmux13s", isOnline: true),
            WorkspaceMac(id: "air", name: "MacBook Air", isOnline: false),
        ]
        let teams = [
            WorkspaceTeam(id: "manaflow", name: "Manaflow", macs: macs),
            WorkspaceTeam(id: "personal", name: "Personal", macs: [macs[1]]),
        ]
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func tabs(_ id: String, _ list: [(WorkspaceTab.Kind, String)]) -> [WorkspaceTab] {
            list.enumerated().map { WorkspaceTab(id: "\(id)-\($0.offset)", kind: $0.element.0, title: $0.element.1) }
        }
        let items = [
            WorkspaceItem(id: "hq", name: "hq", branch: "main", macID: "studio", lastActivity: ago(3), isPinned: true,
                          lastMessage: "Fleet dump for 2026/10/13 is committed.", tabs: tabs("hq", [(.chief, "Chief"), (.terminal, "zsh"), (.terminal, "zsh")])),
            WorkspaceItem(id: "cmux", name: "cmux", branch: "main", macID: "mbp", lastActivity: ago(50), status: .done, isPinned: true,
                          lastMessage: "Merged #20340.", tabs: tabs("cmux", [(.chief, "Chief"), (.terminal, "zsh")])),
            WorkspaceItem(id: "wg", name: "iOS pairing over WireGuard", branch: "feat-cnx-wireguard", macID: "mbp", lastActivity: ago(4),
                          status: .needsAttention, unreadCount: 2,
                          lastMessage: "Chief wants to run ssh mini-cmuxs-mac-mini-2 'cnx-hostd --pair'.",
                          tabs: tabs("wg", [(.chief, "Chief"), (.terminal, "zsh"), (.terminal, "cnx-hostd"), (.browser, "localhost:8787")])),
            WorkspaceItem(id: "rel", name: "Release 0.64 notes", branch: "release/0.64", macID: "studio", lastActivity: ago(38),
                          status: .review, unreadCount: 1, lastMessage: "Draft is ready: 14 entries, 3 need a second look.",
                          tabs: tabs("rel", [(.chief, "Chief"), (.browser, "CHANGELOG.md")])),
            WorkspaceItem(id: "flicker", name: "Fix sidebar flicker on resize", branch: "fix-sidebar-flicker", macID: "studio", lastActivity: ago(2),
                          status: .working, lastMessage: "Rebuilding after the layout fix…",
                          tabs: tabs("flicker", [(.chief, "Chief"), (.terminal, "zsh"), (.terminal, "xcodebuild")])),
            WorkspaceItem(id: "bench", name: "Benchmark 1000 workspaces", branch: "perf-1000-ws", macID: "mini", lastActivity: ago(120),
                          status: .working, lastMessage: "Run 3 of 5: p95 sidebar update 4.1 ms.",
                          tabs: tabs("bench", [(.chief, "Chief"), (.terminal, "bench")])),
            WorkspaceItem(id: "copy", name: "Onboarding copy pass", branch: "onboarding-copy", macID: "mbp", lastActivity: ago(360),
                          lastMessage: "Updated 9 strings in the welcome flow.", tabs: tabs("copy", [(.chief, "Chief"), (.browser, "localhost:3000")])),
            WorkspaceItem(id: "restore", name: "Crash in tab restore", branch: "fix-tab-restore", macID: "mini", lastActivity: ago(560),
                          status: .needsAttention, unreadCount: 1, lastMessage: "Should I delete the corrupt session file?",
                          tabs: tabs("restore", [(.chief, "Chief"), (.terminal, "zsh")])),
            WorkspaceItem(id: "ghostty", name: "Ghostty upstream sync", branch: "update-ghostty", macID: "air", lastActivity: ago(1_560),
                          status: .done, lastMessage: "Submodule bumped and checksums pinned.", tabs: tabs("ghostty", [(.chief, "Chief"), (.terminal, "zig build")])),
            WorkspaceItem(id: "stream", name: "Browser pane video stream", branch: "feat-cnx-browserstream", macID: "studio", lastActivity: ago(2_000),
                          lastMessage: "First frames arrive in 180 ms.", tabs: tabs("stream", [(.chief, "Chief"), (.terminal, "cmux-rd"), (.browser, "localhost:5173")])),
            WorkspaceItem(id: "fleet", name: "Fleet runbook cleanup", branch: "docs-fleet", macID: "mbp", lastActivity: ago(4_300),
                          status: .done, lastMessage: "Removed 6 retired host names.", tabs: tabs("fleet", [(.chief, "Chief")])),
            WorkspaceItem(id: "settings", name: "Settings window parity", branch: "feat-settings", macID: "studio", lastActivity: ago(7_300),
                          lastMessage: "Waiting for the config isolation PR.", tabs: tabs("settings", [(.chief, "Chief"), (.terminal, "zsh")])),
        ]
        return WorkspacesStore(teams: teams, workspaces: items, now: now)
    }
}
