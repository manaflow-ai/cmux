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
