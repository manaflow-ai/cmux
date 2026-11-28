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
import Darwin
import Foundation
import Testing

/// Leo 2026-11-27: "rfd for this would be quite good. i think we can prob do some fast-bench type things for
/// risky areas". Lawrence's NIGHTLY beachballed 2-6 s at a time (c6ff124, 1104 workspaces, a ~160 KB
/// cmux.json): each sidebar flush mapped every Chief-owned row, each row asked every Chief's picture, and
/// each picture sent the whole settings file over the Rust bridge (`welcome.mascotPicked`, cmux#59531).
/// The sidebar fixtures had no Chiefs and a one-key cmux.json, so nothing measured it.
///
/// This is the sidebar's full flush (`SidebarRowFeed` pass with new inputs, every row mapped through
/// `SidebarLaneStatus.applying` with a `chiefAvatar`) at that scale, the avatar built as the app built it
/// in c6ff124: every Chief's face, each from `ChiefPetSettingsRows.chosenPicture` with the real settings
/// file root. It prints `SIDEBAR-CHIEF-FLUSH` and fails over the frame-scale budget.
@MainActor @Suite(.serialized) struct ChiefFaceFlushBenchTests {
    static let host = "install:chief-flush"
    static let workspaces = 1104
    static let chiefs = [HomeChiefAvatars.defaultChief, "agent_scout01", "agent_scout02", "agent_scout03", "agent_scout04"]
    /// One full flush on the main actor at 1104 rows: a few frames, never a beachball.
    static let budgetMs = 250.0

    /// A cmux.json of about 160 KB: the mascot key plus a large unrelated object, as a long-lived config has.
    static func bigConfig() -> String {
        let filler = (0..<1800).map { #""key\#($0)":{"command":"echo \#(String(repeating: "x", count: 48))","title":"bench \#($0)"}"# }
        return #"{"home":{"chiefPetMascot":"fox"},"bench":{"# + filler.joined(separator: ",") + "}}"
    }

    static func cpu() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1_000 + Double(ts.tv_nsec) / 1e6
    }

    @Test func fullSidebarFlushWithChiefsAndABigConfigStaysUnderBudget() async throws {
        let h = try await PerChiefPetTests().make(Self.bigConfig())
        defer { h.tearDown() }
        let bytes = (try? Data(contentsOf: h.url).count) ?? 0
        #expect(bytes > 150_000, "the bench needs Lawrence's settings size")
        let picks = h.picks()
        picks.remember("moon", for: "agent_scout01")

        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)

        // 1104 workspaces, each with one agent chat whose lane a Chief owns (a Chief-started tab).
        let store = DaemonStore(), turns = AgentTurnStateStore(), lanes = AgentLaneStore(), chiefLanes = AgentLaneStore()
        var trees: [WorkspaceSnapshot] = []
        var all: [String: AgentActivityLane] = [:]
        for (c, chief) in Self.chiefs.enumerated() {
            all["chief-\(c)"] = AgentActivityLane(id: "chief-\(c)", name: "chief-\(c)", title: "Chief \(c)", peer: nil, parent: nil, state: .idle,
                                                  since: nil, error: nil, chiefChildren: "kids-\(c)", chiefParticipant: chief)
        }
        for i in 0..<Self.workspaces {
            let id = UInt64(i + 1)
            var tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, cwd: nil)
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-\(i)", harness: "claude"))
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            trees.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "Agent workspace \(i)", screens: [screen]))
            all["s-\(i)"] = AgentActivityLane(id: "s-\(i)", name: "s-\(i)", title: "Agent \(i)", peer: nil, parent: "kids-\(i % Self.chiefs.count)",
                                              state: .working, since: Date(timeIntervalSince1970: 1_000), error: nil, harness: "claude",
                                              step: "Reading file \(i)", cwd: "/tmp/feature-\(i)")
        }
        store.apply(snapshot: DaemonTree(workspaces: trees))
        turns.localHost = Self.host
        lanes.lanes = all
        #expect(lanes.chiefParticipants.count == Self.chiefs.count, "every Chief owns its children")

        // c6ff124's avatar: every Chief's face per row (HomeService.chiefFaces), each picture from the settings file root.
        var avatarCalls = 0
        let chiefAvatar: (String) -> SidebarChiefAvatar? = { chief in
            avatarCalls += 1
            var faces: [String: HomeChiefAvatar] = [:]
            for c in Self.chiefs {
                if let url = ChiefPetSettingsRows.chosenPicture(of: c, picks: picks, uploads: nil, in: h.settings.snapshot, file: h.settings.fileRoot) {
                    faces[c] = .picture(url)
                }
            }
            return SidebarChiefAvatar(home: faces[chief])
        }

        final class Pending { var work: [@MainActor @Sendable () -> Void] = [] }
        let pending = Pending()
        let feed = SidebarRowFeed(schedule: { [pending] in pending.work.append($0) })
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let source = SidebarLaneStatus.applying(feed.rowSource, lanes: lanes, turns: turns, chiefLanes: chiefLanes, chiefAvatar: chiefAvatar)

        var passes: [Double] = []
        for pass in 0..<4 {
            avatarCalls = 0
            let start = Self.cpu()
            feed.beginPass(inputs: pass)  // new inputs: every row maps again, as a settings or theme change does
            let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: machine, rowSource: source)
            _ = feed.fill(sections)
            passes.append(Self.cpu() - start)
            #expect(avatarCalls >= Self.workspaces, "every Chief-owned row asked its avatar (\(avatarCalls))")
        }
        let measured = Array(passes.dropFirst())  // the first pass warms caches
        let worst = measured.max() ?? 0, best = measured.min() ?? 0
        print(String(format: "SIDEBAR-CHIEF-FLUSH workspaces=%d chiefs=%d config_bytes=%d best_ms=%.1f worst_ms=%.1f passes_ms=%@ budget_ms=%.0f",
                     Self.workspaces, Self.chiefs.count, bytes, best, worst, measured.map { String(format: "%.1f", $0) }.joined(separator: ","), Self.budgetMs))
        #expect(worst < Self.budgetMs, "one sidebar flush at \(Self.workspaces) Chief rows took \(Int(worst)) ms on the main actor (budget \(Int(Self.budgetMs)))")
    }
}
