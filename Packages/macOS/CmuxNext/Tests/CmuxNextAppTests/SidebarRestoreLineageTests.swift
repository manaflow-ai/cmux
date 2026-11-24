import AppKit
@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// Leo, 2026-11-22, after restarting cmux NIGHTLY to update: "and then the sidebar re-rendered/re-ordered with some
/// animations". The lineage that nests agent-started sessions under their parents comes from acpmux's lanes
/// (`spawnedBy`), which land seconds after the window's first frame (his relaunch: the home daemon at 2.2 s, the
/// agent transport at 13.3 s). Until then the rows drew loose, then jumped under their parents. The lineage drawn
/// last is saved and held until the lanes are live, and a restore's arrival never moves rows on a spring.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRestoreLineageTests {
    /// Before acpmux's watch has delivered its page, the feed draws the lineage drawn last (the saved one), not
    /// loose rows; once the lanes are live their own lineage wins and is what the next launch saves.
    @Test(.timeLimit(.minutes(1)))
    func theSavedLineageNestsUntilTheLanesAreLive() async throws {
        let fixture = LargeSessionFixture(.large)
        let chats = fixture.chats()
        try #require(chats.count >= 3)
        let id = { (n: Int) in SidebarWorkspaceID(fixture.store.workspaces[chats[n].workspace - 1].id) }
        let (parent, child, adopter) = (id(0), id(1), id(2))
        let defaults = UserDefaults(suiteName: "restore-lineage-\(UUID().uuidString)")!
        // The last run drew the child under its parent while its lanes were live.
        SidebarSessionTree(defaults: defaults).savedParents = [child: parent]
        let tree = SidebarSessionTree(defaults: defaults)
        #expect(tree.state?.parents == [child: parent], "the first frame drew the rows loose: \(String(describing: tree.state?.parents))")

        let lanes = AgentLaneStore()
        let feed = SidebarSessionTreeFeed(recordedParents: AgentSessionParents(defaults: nil))
        feed.start(workspaces: { [store = fixture.store] in store.workspaces }, localHost: LargeSessionFixture.host,
                   lanes: lanes, remote: RemoteAgentSessionLinks(), tree: tree)
        // The feed's first pass over the workspaces, the lanes still down: no row un-nests.
        await LargeSessionFixture.until { feed.workspaces(showing: [LargeSessionFixture.session(chats[1].workspace)]).count == 1 }
        await LargeSessionFixture.drainMain()
        #expect(tree.state?.parents == [child: parent], "the rows un-nested before the lanes landed: \(String(describing: tree.state?.parents))")
        #expect(tree.savedParents == [child: parent], "a pass without the lanes replaced the saved lineage")

        // The lanes land: the child's lane names another parent's session (it moved since), and that lineage wins.
        let session = LargeSessionFixture.session(chats[1].workspace)
        lanes.set(session, AgentActivityLane(id: session, name: session, title: session, peer: nil, parent: nil, state: .idle,
                                             since: nil, error: nil, spawnedBy: LargeSessionFixture.session(chats[2].workspace)))
        lanes.live = true
        await LargeSessionFixture.until { tree.savedParents == [child: adopter] }
        #expect(tree.state?.parents == [child: adopter])
        #expect(SidebarSessionTree(defaults: defaults).savedParents == [child: adopter], "the live lineage was not kept for the next launch")

        // The child's lane ends its lineage: the live tree has none, and the saved lineage follows it.
        lanes.set(session, nil)
        await LargeSessionFixture.until { SidebarSessionTree(defaults: defaults).savedParents.isEmpty }
        #expect(tree.state == nil || tree.state?.parents.isEmpty == true)
    }

    /// With no acpmux here, no lanes come to replace the saved lineage: it is not drawn.
    @Test func noAcpmuxDropsTheSavedLineage() {
        let defaults = UserDefaults(suiteName: "restore-lineage-\(UUID().uuidString)")!
        SidebarSessionTree(defaults: defaults).savedParents = [WorkspaceID("b"): WorkspaceID("a")]
        let tree = SidebarSessionTree(defaults: defaults)
        SidebarSessionTreeFeed.shared.dropSavedLineage(tree: tree)
        #expect(tree.state == nil)
        #expect(SidebarSessionTree(defaults: defaults).savedParents.isEmpty)
    }

    /// The lineage arriving right after a click or key (inside the user-intent window) still shows in one step.
    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func theLineageArrivingAfterAClickMovesNoRowOnASpring() throws {
        let start = Self.sections([1, 3, 4, 2])
        let model = SidebarModel(sections: start)
        let shared = SidebarSessionTree.shared
        let before = shared.state
        defer { shared.state = before }
        shared.state = nil
        let (sidebar, window) = Self.sidebar(model, onScreen: true)
        defer { window.close() }
        try #require(window.screen != nil)
        sidebar.list.pointerIsOverList = { (_: SidebarListView) in false }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        model.noteUserIntent()
        shared.state = SidebarSessionTreeState(parents: [WorkspaceID("2"): WorkspaceID("1")])
        sidebar.renderNow()

        #expect(Self.drawnOrder(sidebar.list) == ["1", "2", "3", "4"].map(WorkspaceID.init), "the lineage did not show")
        #expect(Self.rowMotion(in: sidebar.list).isEmpty, "rows slid for the lineage's arrival: \(Self.rowMotion(in: sidebar.list))")
    }

    /// The launch order hold's release (the live order shows) right after a click or key still shows in one step.
    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func theLaunchOrderReleaseMovesNoRowOnASpring() throws {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        model.setSections(start)
        let (sidebar, window) = Self.sidebar(model, onScreen: true)
        defer { window.close() }
        try #require(window.screen != nil)
        sidebar.list.pointerIsOverList = { (_: SidebarListView) in false }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        model.holdsLaunchOrder = true
        model.setSections(Self.sections([4, 1, 2, 3]))
        sidebar.renderNow()
        #expect(Self.drawnOrder(sidebar.list) == ["1", "2", "3", "4"].map(WorkspaceID.init), "the hold did not keep the drawn order")
        model.noteUserIntent()
        model.holdsLaunchOrder = false
        sidebar.renderNow()

        #expect(Self.drawnOrder(sidebar.list) == ["4", "1", "2", "3"].map(WorkspaceID.init), "the live order did not show")
        #expect(Self.rowMotion(in: sidebar.list).isEmpty, "rows slid for the hold's release: \(Self.rowMotion(in: sidebar.list))")
    }

    // MARK: Helpers

    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        [CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                        nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID("\($0)"), title: "w\($0)")) })]
    }

    private static func sidebar(_ model: SidebarModel, onScreen: Bool) -> (SidebarView, NSWindow) {
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        if onScreen { window.orderFrontRegardless() }
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        return (sidebar, window)
    }

    private static func drawnOrder(_ list: SidebarListView) -> [WorkspaceID] {
        list.displayed.rows.compactMap { if case let .workspace(id) = $0.key { id } else { nil } }
    }

    /// Rows on the render server's spring, off their slot, or still fading in.
    private static func rowMotion(in list: SidebarListView) -> [String] {
        list.displayed.rows.compactMap { row -> String? in
            guard case .workspace = row.key, let view = list.rowViews[row.key] else { return nil }
            let target = list.frame(for: row)
            let springs = view.layer.map { layer in
                (layer.animationKeys() ?? []).contains { key in
                    (layer.animation(forKey: key) as? CASpringAnimation).map { $0.isAdditive && $0.keyPath == "position" } ?? false
                }
            } ?? false
            return springs || abs(view.frame.minY - target.minY) > 0.5 || view.alphaValue < 0.99
                ? "\(row.key) at \(view.frame.minY), slot \(target.minY)\(springs ? ", springing" : "")" : nil
        }
    }
}
