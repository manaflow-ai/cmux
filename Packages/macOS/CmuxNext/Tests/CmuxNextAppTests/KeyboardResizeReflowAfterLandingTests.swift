import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS K3, second part. After films rk-k3ff-b2..b5 (content hold 3e14e9205bb): H/L drops went from 4-8 to 0-2
/// per press, and the profile (rk-k3ff-x1, app clock) names the rest: the one content layout ran inside a motion
/// frame: in the key's own turn for the growing panes (page, chat and CEF child window at their final size, 10-24 ms)
/// and in the landing frame for the shrinking ones (11-17 ms). No content may lay out in the key turn or in any frame
/// of the spring: each pane's content keeps its start size through the motion and lays out once, after the landing
/// frame's commit (`LayoutViewContext.afterCommit`), when nothing moves.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeReflowAfterLandingTests {
    typealias Panes = KeyboardResizeContentHoldTests.Panes

    @Test(arguments: [LayoutDirection.left, .right])
    func contentLaysOutOnlyAfterTheLandingFrame(direction: LayoutDirection) throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for view in provider.views.values { view.sizes.removeAll() }
        #expect(PaneResize.press("p2", direction, model: model, view: root))
        root.syncWithModel()
        var frames = 0
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
        }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the press did not spring")
        for (pane, view) in provider.views {
            #expect(view.sizes.isEmpty, "\(pane)'s content laid out in the key turn or a motion frame: \(view.sizes)")
        }
        // After the landing frame's commit: one layout each, at the size the pane rests at.
        for work in afterCommit { work() }
        root.layoutSubtreeIfNeeded()
        for (pane, view) in provider.views {
            let host = try #require(root.context.hosts[pane])
            #expect(view.sizes.count == 1, "\(pane)'s content laid out \(view.sizes.count) times after the landing")
            #expect(view.frame.size == view.superview?.bounds.size, "\(pane)'s content is not at its rest size: \(view.frame.size) in \(String(describing: view.superview?.bounds.size)) (host \(host.frame.size))")
        }
    }

    /// The app's pane content with a terminal in each pane (cmux-ad m18: each frame at the pane's size, text re-wrapped
    /// at it; the PTY's size coalesced, one per refresh): no grid goes in the key's turn, at most one per terminal with the press's first frame (RESIZE P0 7)
    /// (m6 sent the final grid there, one per press), at most the first frame's own grid with that frame (RESIZE P0 7), and the last
    /// grid each PTY gets is the grid its view rests at; in every frame the containers (the terminal hosts) take their
    /// pane's area and each surface the size its host shows it at, so its text follows the pane (S3 laid the surface out
    /// once per press: the text froze, then jumped); at the landing's release each surface rests at its host's size.
    @Test(arguments: [LayoutDirection.left, .right])
    func theTerminalFollowsItsPaneInEveryFrameAndItsPTYEndsAtTheLandingsGrid(direction: LayoutDirection) async throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        func sizes() throws -> [PaneID: (host: CGSize, surface: CGSize)] {
            try Dictionary(uniqueKeysWithValues: panes.map { pane in
                let session = try #require(rig.provider.sessions[pane]?.session)
                return (pane, (session.view.frame.size, session.surfaceView.frame.size))
            })
        }
        for pane in panes { _ = try await PaneContentPolicyTests.grids(pane, rig) }
        let reports = TerminalSurfaceView.gridReports
        let start = try sizes()
        var startGrids: [PaneID: TerminalGridSize] = [:]
        for pane in panes { startGrids[pane] = try PaneContentPolicyTests.surface(pane, in: rig).fittedGrid }
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(TerminalSurfaceView.gridReports == reports, "the key's turn sent \(TerminalSurfaceView.gridReports - reports) grids: none goes before its refresh")
        try #require(rig.frame(), "the press did not spring")
        let atPress = try sizes()
        // The first grid each terminal showed that differs from its start grid: the press's first frames can move a pane less
        // than a cell (the spring starts slowly), so that grid can be a later frame's than the first (green4 87a059b7: 73 at
        // frame 1 = the start grid, 74 the first new grid).
        var firstChanged: [PaneID: TerminalGridSize] = [:]
        func noteFirstGrids() throws {
            for pane in panes where firstChanged[pane] == nil {
                if let grid = try PaneContentPolicyTests.surface(pane, in: rig).fittedGrid, grid != startGrids[pane] { firstChanged[pane] = grid }
            }
        }
        try noteFirstGrids()
        // RESIZE P0 7: the first frame's landed grid goes in that frame's turn, at most one per terminal.
        #expect(TerminalSurfaceView.gridReports - reports <= panes.count, "the press's first frame sent \(TerminalSurfaceView.gridReports - reports) grids for \(panes.count) terminals")
        var frames = 1, hostsOff: [String] = [], surfacesOff: [String] = []
        func check(_ label: String) throws {
            for pane in panes {
                let session = try #require(rig.provider.sessions[pane]?.session)
                let area = try #require(session.view.superview)
                let host = session.view, surface = session.surfaceView.frame.size
                if host.frame.size != area.bounds.size { hostsOff.append("\(label): \(pane)'s host \(host.frame.size) in \(area.bounds.size)") }
                let shown = host.surfaceSize(forHostSize: host.bounds.size)
                if surface != shown { surfacesOff.append("\(label): \(pane)'s surface \(surface) in a \(shown) area") }
            }
        }
        try check("frame 1")
        while frames < 240, rig.frame() {
            frames += 1
            try check("frame \(frames)")
            try noteFirstGrids()
        }
        rig.commit()
        try check("after the landing")
        let landed = try sizes()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        for pane in panes {
            #expect(atPress[pane]?.surface != start[pane]?.surface, "\(pane)'s surface did not follow its pane in the press's first frame")
            #expect(landed[pane]?.surface != atPress[pane]?.surface, "\(pane)'s surface stayed at its first frame's size through the spring")
        }
        #expect(surfacesOff.isEmpty, "\(surfacesOff.count) frames showed a surface off its pane's size: \(surfacesOff.prefix(3))")
        #expect(hostsOff.isEmpty, "a terminal host did not lay out at its pane's area in a frame: \(hostsOff.prefix(3))")
        // Per terminal, exact (RESIZE P0 8, review of 28a640183a7): the PTY got the final grid, or the first new grid a frame
        // showed (RESIZE P0 7: the first grid of a refresh goes at once; these frames run in one turn, so no refresh ends a
        // window and the rest go as the final grid) and then the final grid. m6 (the final grid with the first frame, one per
        // press) fails: it is neither.
        for pane in panes {
            let grids = try await PaneContentPolicyTests.grids(pane, rig)
            let final = try #require(try PaneContentPolicyTests.surface(pane, in: rig).fittedGrid)
            let first = try #require(firstChanged[pane], "\(pane)'s grid never changed from its start grid \(String(describing: startGrids[pane]))")
            #expect(first != final, "\(pane)'s first new grid already was the landing's grid \(final)")
            #expect(grids == [final] || grids == [first, final],
                    "\(pane)'s PTY got \(grids), not [its first new grid \(first) (start \(String(describing: startGrids[pane]))),] then its view's rest grid \(final)")
        }
    }
}
