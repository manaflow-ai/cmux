import AppKit
import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextChiefPetWiring
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextHomeEngine
import CmuxNextSidebar
import Foundation

/// The app's side of a sidebar with Chiefs, for `SidebarLagBench` and `SidebarScrollBench` (their `appTick`).
/// Lawrence's NIGHTLY beachballed with 1104 workspaces, each a chat a Chief started, and a ~160 KB cmux.json;
/// the bench fixtures had no Chiefs and a one-key settings file, so nothing measured that path.
///
/// `workspaces` daemon workspaces, each with one agent chat whose lane five Chiefs own (`chiefChildren` /
/// `parent`, as ChiefFaceFlushBenchTests builds them), a settings file of `ChiefFaceFlushBenchTests`'s shape
/// (`bigConfig`, ~160 KB), and the row mapping the sidebar uses: a `SidebarRowFeed` over
/// `SidebarLaneStatus.applying` with the `chiefAvatar` SidebarBridge passes (every Chief's face from
/// `HomeService.chiefFaces`, each picture from `ChiefPetSettingsRows.chosenPicture` with the real settings
/// file root, as `AppServices.chosenPicture` asks it). Keep `avatar(_:)` equal to SidebarBridge's closure.
///
/// A tick changes the ticked chats' lanes (their step), as the acpmux watch does, then runs the feed's flush,
/// which maps those rows again; the mapped Chief avatar goes on the bench's row.
@MainActor
final class SidebarChiefFixture {
    static let host = "install:sidebar-chiefs"
    static let chiefs = [HomeChiefAvatars.defaultChief, "agent_scout01", "agent_scout02", "agent_scout03", "agent_scout04"]

    /// A cmux.json of about 160 KB: the mascot key plus a large unrelated object, as a long-lived config has
    /// (ChiefFaceFlushBenchTests.bigConfig's shape).
    static func bigConfig() -> String {
        let filler = (0..<1800).map { #""key\#($0)":{"command":"echo \#(String(repeating: "x", count: 48))","title":"bench \#($0)"}"# }
        return #"{"home":{"chiefPetMascot":"fox"},"bench":{"# + filler.joined(separator: ",") + "}}"
    }

    final class Pending { var work: [@MainActor @Sendable () -> Void] = [] }

    let workspaces: Int
    let harness: PerChiefPetTests.Harness
    /// The settings file's size on disk.
    let configBytes: Int
    let store = DaemonStore(), turns = AgentTurnStateStore(), lanes = AgentLaneStore(), chiefLanes = AgentLaneStore()
    let feed: SidebarRowFeed
    let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private let pending = Pending()
    private let picks: ChiefMascotPicks
    private var source: SidebarMapping.RowSource!
    /// The feed's workspace ids in sidebar order (index i is chat `s-i`).
    private(set) var ids: [WorkspaceID] = []
    /// The rows the feed mapped last, by id.
    private(set) var mapped: [WorkspaceID: SidebarWorkspace] = [:]
    /// `chiefAvatar` calls since the last `resetCounts()`.
    private(set) var avatarCalls = 0
    private var inputs = 0, tickCount = 0

    private init(workspaces: Int, harness: PerChiefPetTests.Harness) {
        self.workspaces = workspaces
        self.harness = harness
        configBytes = (try? Data(contentsOf: harness.url).count) ?? 0
        picks = harness.picks()
        picks.remember("moon", for: "agent_scout01")
        let pending = pending
        feed = SidebarRowFeed(schedule: { pending.work.append($0) })
    }

    static func make(workspaces: Int) async throws -> SidebarChiefFixture {
        let h = try await PerChiefPetTests().make(bigConfig())
        let fixture = SidebarChiefFixture(workspaces: workspaces, harness: h)
        fixture.build()
        return fixture
    }

    func tearDown() {
        feed.reset()
        harness.tearDown()
    }

    /// SidebarBridge's `chiefAvatar`: `SidebarChiefAvatar(home: services.home.chiefFaces[chief])`.
    private func avatar(_ chief: String) -> SidebarChiefAvatar? {
        avatarCalls += 1
        let settings = harness.settings, picks = picks
        let faces = HomeService.chiefFaces(chiefs: Set(Self.chiefs), own: [:]) {
            ChiefPetSettingsRows.chosenPicture(of: $0, picks: picks, uploads: nil, in: settings.snapshot, file: settings.fileRoot)
        }
        return SidebarChiefAvatar(home: faces[chief])
    }

    private func lane(_ i: Int, step: String) -> AgentActivityLane {
        AgentActivityLane(id: "s-\(i)", name: "s-\(i)", title: "Agent \(i)", peer: nil, parent: "kids-\(i % Self.chiefs.count)",
                          state: .working, since: Date(timeIntervalSince1970: 1_000), error: nil, harness: "claude",
                          step: step, cwd: "/tmp/feature-\(i)")
    }

    private func build() {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        var trees: [WorkspaceSnapshot] = []
        var all: [String: AgentActivityLane] = [:]
        for (c, chief) in Self.chiefs.enumerated() {
            all["chief-\(c)"] = AgentActivityLane(id: "chief-\(c)", name: "chief-\(c)", title: "Chief \(c)", peer: nil, parent: nil, state: .idle,
                                                  since: nil, error: nil, chiefChildren: "kids-\(c)", chiefParticipant: chief)
        }
        for i in 0..<workspaces {
            let id = UInt64(i + 1)
            var tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, cwd: nil)
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-\(i)", harness: "claude"))
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            trees.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "Agent workspace \(i)", screens: [screen]))
            all["s-\(i)"] = lane(i, step: "Reading file \(i)")
        }
        store.apply(snapshot: DaemonTree(workspaces: trees))
        turns.localHost = Self.host
        lanes.lanes = all
        source = SidebarLaneStatus.applying(feed.rowSource, lanes: lanes, turns: turns, chiefLanes: chiefLanes,
                                            chiefAvatar: { [unowned self] in self.avatar($0) })
        feed.onChange = { [unowned self] rows in for row in rows { self.mapped[row.id] = row } }
        remap()
        ids = Self.flatten(feed.fill(SidebarMapping.shared.sections(store.sidebarSections, machine: machine, rowSource: source))).map(\.id)
    }

    /// The pass a settings or theme change runs: new inputs, so every row maps again.
    func remap() {
        inputs += 1
        feed.beginPass(inputs: inputs)
        for row in Self.flatten(feed.fill(SidebarMapping.shared.sections(store.sidebarSections, machine: machine, rowSource: source))) {
            mapped[row.id] = row
        }
        runPending()
    }

    /// Chats `chats` (indexes into `ids`) report a new step, then the feed's flush maps their rows again.
    func tick(_ chats: [Int]) {
        tickCount += 1
        for i in chats { lanes.set("s-\(i)", lane(i, step: "Editing file \(tickCount % 17)")) }
        runPending()
    }

    func resetCounts() { avatarCalls = 0 }

    private func runPending() {
        while !pending.work.isEmpty {
            let work = pending.work
            pending.work.removeAll()
            for job in work { job() }
        }
    }

    /// The benches' `appTick`: bench row k is chat `k % workspaces`; its mapped Chief avatar goes on the row.
    func appTick(_ rows: inout [SidebarWorkspace], _ ticked: [Int]) {
        let chats = ticked.map { $0 % workspaces }
        tick(chats)
        for (k, chat) in zip(ticked, chats) where chat < ids.count {
            rows[k].chiefAvatar = mapped[ids[chat]]?.chiefAvatar
        }
    }

    static func flatten(_ sections: [CmuxNextSidebar.SidebarSection]) -> [SidebarWorkspace] {
        func rows(_ nodes: [CmuxNextSidebar.SidebarNode]) -> [SidebarWorkspace] {
            nodes.flatMap { node -> [SidebarWorkspace] in
                switch node {
                case .workspace(let w): [w]
                case .group(let g): g.workspaces
                default: []
                }
            }
        }
        return sections.flatMap { rows($0.nodes) }
    }
}
