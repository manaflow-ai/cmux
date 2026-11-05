import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
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
    /// at it; the PTY's size coalesced, about 25 ms): no grid goes in the key's turn or with the press's first frame
    /// (m6 sent the final grid there, one per press; a synchronous run of frames is inside one 25 ms window), and the last
    /// grid each PTY gets is the grid its view rests at; in every frame the containers (the terminal hosts) take their
    /// pane's area and each surface the size its host shows it at, so its text follows the pane (S3 laid the surface out
    /// once per press: the text froze, then jumped); at the landing's release each surface rests at its host's size.
    @Test(arguments: [LayoutDirection.left, .right])
    func theTerminalFollowsItsPaneInEveryFrameAndItsPTYEndsAtTheLandingsGrid(direction: LayoutDirection) async throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(), "the switch motion.frameOwner.terminals did not turn on")
        let panes: [PaneID] = ["p1", "p2"]
        func sizes() throws -> [PaneID: (host: CGSize, surface: CGSize)] {
            try Dictionary(uniqueKeysWithValues: panes.map { pane in
                let session = try #require(rig.provider.sessions[pane]?.session)
                return (pane, (session.view.frame.size, session.surfaceView.frame.size))
            })
        }
        let reports = TerminalSurfaceView.gridReports
        let start = try sizes()
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        try #require(rig.frame(), "the press did not spring")
        let atPress = try sizes()
        #expect(TerminalSurfaceView.gridReports == reports, "up to its first frame the press sent \(TerminalSurfaceView.gridReports - reports) grids: none goes before its 25 ms")
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
        try await KeyboardResizeContentHoldTests.expectEachPTYEndsAtItsViewsGrid(panes, rig)
    }

    /// The kill switch (`motion.frameOwner.terminals` off; review of #35470 at c4d6c936c92, T5: the base checked this
    /// path). cmux-ad m18 deleted the key hold in both states: the producer (the terminal surface) takes its host's area in
    /// every frame of the spring, as with the switch on (it laid out once, at its final size, before), no grid goes by
    /// the press's first frame, and the last grid each PTY gets is its view's at rest.
    @Test(arguments: [LayoutDirection.left, .right])
    func theProducerFollowsItsPaneWithTheSwitchOffToo(direction: LayoutDirection) async throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(false), "the switch motion.frameOwner.terminals did not turn off")
        let panes: [PaneID] = ["p1", "p2"]
        let reports = TerminalSurfaceView.gridReports
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        try #require(rig.frame(), "the press did not spring")
        #expect(TerminalSurfaceView.gridReports == reports, "up to its first frame the press sent \(TerminalSurfaceView.gridReports - reports) grids: none goes before its 25 ms")
        var frames = 1, off: [String] = [], sizes: [PaneID: [CGSize]] = [:]
        func check(_ label: String) throws {
            for pane in panes {
                let session = try #require(rig.provider.sessions[pane]?.session)
                let area = try #require(session.view.superview)
                let host = session.view, surface = session.surfaceView.frame.size
                if sizes[pane]?.contains(surface) != true { sizes[pane, default: []].append(surface) }
                if host.frame.size != area.bounds.size { off.append("\(label): \(pane)'s host \(host.frame.size) in \(area.bounds.size)") }
                let shown = host.surfaceSize(forHostSize: host.bounds.size)
                if surface != shown { off.append("\(label): \(pane)'s surface \(surface) in a \(shown) area") }
            }
        }
        try check("frame 1")
        while frames < 240, rig.frame() {
            frames += 1
            try check("frame \(frames)")
        }
        rig.commit()
        try check("after the landing")
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a terminal host or surface off its pane: \(off.prefix(3))")
        for pane in panes {
            #expect((sizes[pane]?.count ?? 0) > 3, "\(pane)'s surface took \(sizes[pane]?.count ?? 0) sizes in a \(frames)-frame spring: it did not follow its pane")
        }
        try await KeyboardResizeContentHoldTests.expectEachPTYEndsAtItsViewsGrid(panes, rig)
    }
}
