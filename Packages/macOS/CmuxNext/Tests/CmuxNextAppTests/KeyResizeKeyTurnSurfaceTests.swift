import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B: the key's own turn of a keyboard pane resize (`PaneResize.press`).
///
/// In the 120 Hz films the first frame of a column key (Ctrl-Shift-H, L) shows nothing new: the first frame tick after
/// the key comes one vsync late (round s1b-keyturn2-18, FEAT DOGFOOD BUILD e0e34bd6, cmux18, 2x: key turn 7.7 / 8.2 ms
/// to its commit, then the first tick 7.3 / 8.9 ms of main time). The key's turn synced the layout and presented it
/// (`PaneResize.press` -> `syncWithModel` -> `syncScroll` -> `applyPresentation`): every pane host's rest size, the
/// content's rest announcement (`PaneHostView.announceRest`: each terminal surface took its rest size,
/// `ghostty_surface_set_size`, and sent its final grid), clips, dividers, the overlay sync and a Core Animation commit,
/// then the first tick presented again.
///
/// The rule (the refactor owner's decision, 2026-11-03): a resize press changes the model and asks for a frame. It lays
/// nothing out, presents nothing, announces no rest and sizes no surface in its own turn, and nothing between it and
/// the next frame tick does (the layout's observation turn included). The first tick syncs the model and presents
/// once: the panes move in that tick, and each terminal sends its one final grid there (RESIZE KEYS: one grid per
/// press, now no later than the first tick instead of in the key's turn).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeKeyTurnSurfaceTests {
    typealias OneGrid = KeyboardResizeOneGridReportTests

    /// Lets the main actor run what the key's turn left queued (the layout's observation of the model), without a
    /// display frame and without waiting on a clock.
    static func drainTurns() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Ctrl-Shift-H, L, K or J on p2 with a terminal in each pane: the key's turn and the turns after it up to the next
    /// frame resize no terminal surface and send no grid; the first frame tick sends each terminal's final grid, once;
    /// after the landing each surface rests at its host's size and sent no other grid.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressResizesNoTerminalSurfaceBeforeItsFirstFrame(direction: LayoutDirection) async throws {
        let rig = try OneGrid.Rig(direction == .left || direction == .right ? OneGrid.pair : OneGrid.stack)
        defer { rig.close() }
        // The launch's grids (the first layout) are not this press's.
        for pane in rig.panes { _ = try await rig.grids(pane) }
        var logs: [PaneID: OneGrid.SizeLog] = [:]
        for pane in rig.panes { logs[pane] = OneGrid.SizeLog(try rig.terminal(pane).surface) }

        // The key's turn, and the main turns after it before any display frame.
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        await Self.drainTurns()
        var beforeFrame: [String] = []
        for pane in rig.panes {
            let sizes = try #require(logs[pane]).sizes
            if !sizes.isEmpty { beforeFrame.append("\(pane.rawValue) surface \(sizes)") }
            let grids = try await rig.grids(pane)
            if !grids.isEmpty { beforeFrame.append("\(pane.rawValue) grids \(grids)") }
        }
        #expect(beforeFrame.isEmpty, "the key's turn sized terminal surfaces or sent grids before the first frame: \(beforeFrame)")

        // The first frame tick: each terminal hears its rest size and sends its final grid.
        try #require(rig.root.advanceFrame(1.0 / 120), "the press did not spring")
        rig.root.layoutSubtreeIfNeeded()
        var atFirstFrame: [PaneID: [TerminalGridSize]] = [:]
        for pane in rig.panes { atFirstFrame[pane] = try await rig.grids(pane) }

        // The rest of the spring, the landing and its commit.
        rig.settle()
        rig.commit()
        for pane in rig.panes {
            let terminal = try rig.terminal(pane)
            let final = try #require(terminal.surface.fittedGrid, "\(pane.rawValue)'s terminal fits no grid")
            #expect(atFirstFrame[pane] == [final],
                    "\(pane.rawValue): the first frame asked the PTY for \(atFirstFrame[pane] ?? []), not the final grid \(final) once")
            #expect(try await rig.grids(pane).isEmpty, "\(pane.rawValue): after the first frame the PTY was asked for another grid")
            let host = terminal.session.view
            #expect(terminal.surface.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                    "\(pane.rawValue)'s surface rests at \(terminal.surface.frame.size) in a \(host.bounds.size) host")
        }
    }

    /// The app's pane content (a tab strip over a content view that counts its layouts) in p1 | p2 and p1 over p2.
    final class Panes: LayoutPaneContentProvider {
        final class Content: NSView {
            var layouts = 0
            override func layout() {
                layouts += 1
                super.layout()
            }
        }

        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var contents: [PaneID: Content] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = Content()
            view.show(content)
            views[pane] = view
            contents[pane] = content
            return view
        }
    }

    /// Ctrl-Shift-H, L, K or J on p2: the key's turn and the turns after it up to the next frame present nothing (no
    /// presentation pass, no pane host frame, no layout of any pane content); the first frame tick presents once and the
    /// panes move in it.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressPresentsNothingUntilItsFirstFrameWhichMovesThePanes(direction: LayoutDirection) async throws {
        _ = NSApplication.shared
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        root.context.afterCommit = { _ in } // the landing is not part of this test
        let screen = try #require(root.screenViews["s"])
        let hosts = [try #require(root.context.hosts["p1"]), try #require(root.context.hosts["p2"])]
        // The rig's own first main turns (each pane content's observations start, and mark it for layout) run before the
        // press, so what the turns after the press lay out is the press's (red run 76f88cfe counted them as the press's).
        await Self.drainTurns()
        root.layoutSubtreeIfNeeded()
        let frames = hosts.map(\.frame)
        let passes = screen.presentationPasses
        for content in provider.contents.values { content.layouts = 0 }

        #expect(PaneResize.press("p2", direction, model: model, view: root))
        await Self.drainTurns()
        #expect(screen.presentationPasses == passes, "the key's turn presented the layout \(screen.presentationPasses - passes) times")
        #expect(hosts.map(\.frame) == frames, "the key's turn moved pane hosts: \(hosts.map(\.frame)) from \(frames)")
        let laidOut = provider.contents.filter { $0.value.layouts > 0 }.map { "\($0.key.rawValue) \($0.value.layouts)" }.sorted()
        #expect(laidOut.isEmpty, "the key's turn laid pane content out: \(laidOut)")

        // The first frame tick: one presentation, and the panes move.
        try #require(root.advanceFrame(1.0 / 120), "the press did not spring")
        #expect(screen.presentationPasses == passes + 1, "the first frame presented \(screen.presentationPasses - passes) times, not once")
        #expect(hosts.map(\.frame) != frames, "the first frame after the key did not move the panes")
    }
}
