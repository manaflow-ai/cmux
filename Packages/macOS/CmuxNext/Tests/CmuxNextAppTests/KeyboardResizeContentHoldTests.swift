import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS K3 (cmux-ad 2026-11-02 P0; lead 21:1xZ: "hold pane content during a key resize spring, one reflow at
/// the landing"). Film rk-browser-agent (feat 507438d): with a browser page and an agent chat right of the divider,
/// every Ctrl-Shift-H/L lost 5-8 refreshes. Profile rk-xtpa-browser-agent: no single item over 8.3 ms; each dropped
/// frame (9-26 ms) was the pane contents laid out at the spring's live size: the CA commit (tracking areas, drag
/// regions, tab label glyphs, constraints), the browser chrome, the CEF content view and its child window, the chat's
/// SwiftUI graph. During a key resize spring each pane's content keeps its size (clipped) and lays out once.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeContentHoldTests {
    final class Recorder: NSView {
        var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var views: [PaneID: Recorder] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = Recorder()
            views[pane] = view
            return view
        }
    }

    @Test(arguments: [LayoutDirection.left, .right])
    func eachPaneContentResizesAtMostOncePerKeyPress(direction: LayoutDirection) throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        for view in provider.views.values { view.sizes.removeAll() }
        let host1 = try #require(root.context.hosts["p1"]), host2 = try #require(root.context.hosts["p2"])
        let before = (host1.frame, host2.frame)
        #expect(PaneResize.press("p2", direction, model: model, view: root))
        root.syncWithModel()
        var frames = 0
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
        }
        root.layoutSubtreeIfNeeded()
        for work in afterCommit { work() }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(host1.frame != before.0 && host2.frame != before.1, "the press moved nothing")
        for (pane, view) in provider.views {
            #expect(view.sizes.count <= 1, "\(pane)'s content resized \(view.sizes.count) times in one key press: \(view.sizes.prefix(4))")
            #expect(view.frame.size == view.superview?.bounds.size, "\(pane) did not land at its final size")
        }
    }

    /// The app's pane content with a terminal in each pane (cmux-ad m6, the lead's contract: pixels per frame, program size
    /// per press): in every frame of the spring each terminal host (the container) takes its pane's content area, and its
    /// surface takes the size the host shows it at, so the text follows the pane; the press asks each PTY for one grid.
    /// FRAME OWNER S3 held the surface at its final size through the press (one size per press): the text froze, then
    /// jumped (Lawrence on dogfood 363e39f2).
    @Test func theTerminalFollowsItsPaneInEveryFrameAndSendsOneGridPerTerminal() throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(), "the switch motion.frameOwner.terminals did not turn on")
        let panes: [PaneID] = ["p1", "p2"]
        var hosts: [PaneID: [CGSize]] = [:], surfaces: [PaneID: [CGSize]] = [:], off: [String] = []
        var last: [PaneID: (host: CGSize, surface: CGSize)] = [:]
        func note(_ label: String) throws {
            for pane in panes {
                let session = try #require(rig.provider.sessions[pane]?.session)
                let area = try #require(session.view.superview, "\(pane)'s terminal host is not in its pane")
                let now = (host: session.view.frame.size, surface: session.surfaceView.frame.size)
                if let was = last[pane] {
                    if now.host != was.host { hosts[pane, default: []].append(now.host) }
                    if now.surface != was.surface { surfaces[pane, default: []].append(now.surface) }
                }
                last[pane] = now
                if now.host != area.bounds.size { off.append("\(label): \(pane)'s host \(now.host) in its area \(area.bounds.size)") }
                let shown = session.view.surfaceSize(forHostSize: session.view.bounds.size)
                if now.surface != shown { off.append("\(label): \(pane)'s surface \(now.surface) in a \(shown) area") }
            }
        }
        let reports = TerminalSurfaceView.gridReports
        try note("at rest")
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try note("the key's turn")
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            try note("frame \(frames)")
        }
        rig.commit()
        try note("after the landing")
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a terminal host or surface off its pane: \(off.prefix(3))")
        for pane in panes {
            #expect((surfaces[pane] ?? []).count > 3, "\(pane)'s surface took \(surfaces[pane]?.count ?? 0) sizes in a \(frames)-frame spring: its text did not follow its pane")
            #expect((hosts[pane] ?? []).count > 3, "\(pane)'s terminal host took \(hosts[pane]?.count ?? 0) sizes in a \(frames)-frame spring")
        }
        #expect(TerminalSurfaceView.gridReports - reports == UInt64(panes.count), "the press sent \(TerminalSurfaceView.gridReports - reports) grids for \(panes.count) terminals")
    }

    /// The default (switch off; review of #35470 at c4d6c936c92, T5: the base checked this path). FRAME OWNER S3, the
    /// app's pane content with a terminal in each pane: the containers (each terminal host) take their pane's content
    /// area in every frame of the spring, and the producer (the terminal surface) takes a new size once, its final size
    /// in the key's turn, and never again in the press.
    @Test func theProducerResizesOnceWithTheSwitchOff() throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(false), "the switch motion.frameOwner.terminals did not turn off")
        let panes: [PaneID] = ["p1", "p2"]
        var hosts: [PaneID: [CGSize]] = [:], surfaces: [PaneID: [CGSize]] = [:], off: [String] = []
        var last: [PaneID: (host: CGSize, surface: CGSize)] = [:]
        func note(_ label: String) throws {
            for pane in panes {
                let session = try #require(rig.provider.sessions[pane]?.session)
                let area = try #require(session.view.superview, "\(pane)'s terminal host is not in its pane")
                let now = (host: session.view.frame.size, surface: session.surfaceView.frame.size)
                if let was = last[pane] {
                    if now.host != was.host { hosts[pane, default: []].append(now.host) }
                    if now.surface != was.surface { surfaces[pane, default: []].append(now.surface) }
                }
                last[pane] = now
                if now.host != area.bounds.size { off.append("\(label): \(pane)'s host \(now.host) in its area \(area.bounds.size)") }
            }
        }
        try note("at rest")
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try note("the key's turn")
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            try note("frame \(frames)")
        }
        rig.commit()
        try note("after the landing")
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "a terminal host (a container) did not follow its pane: \(off.prefix(3))")
        for pane in panes {
            let session = try #require(rig.provider.sessions[pane]?.session)
            #expect((surfaces[pane] ?? []).count <= 1, "\(pane)'s surface (the producer) took \(surfaces[pane]?.count ?? 0) sizes in one press")
            #expect((hosts[pane] ?? []).count > 3, "\(pane)'s terminal host took \(hosts[pane]?.count ?? 0) sizes in a \(frames)-frame spring")
            let host = session.view
            #expect(session.surfaceView.frame.size == host.surfaceSize(forHostSize: host.bounds.size), "\(pane)'s surface did not land at its host's size")
        }
    }
}
