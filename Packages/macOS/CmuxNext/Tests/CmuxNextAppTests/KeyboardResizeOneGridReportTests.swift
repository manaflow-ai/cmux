import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import Testing

/// FRAME OWNER REFACTOR S3a (D1, a regression of #32635, RESIZE KEYS K3). The `sigwinch` TUI counted 24 SIGWINCH for
/// 8 key presses on builds with #32635 and 8 on builds without it; film rk-browser-agent (build 52788515, frame 269)
/// showed the program's start layout (35 columns) for one frame between frames at the final grid (38 columns).
///
/// A key resize holds each pane's content at its start size and lets it go after the landing frame's commit
/// (`PaneHostView.releaseHeldContent`). The release sets the pane content's frame only: its content host and the
/// terminal host in it keep the start size until the next layout pass, and the terminal lets its surface hold go
/// before that pass, from the stale host. The surface takes its start size again and sends the start grid; the next
/// pass sends the final grid again: final, start, final for one press. One press must send each terminal's PTY one
/// grid, the final one, no later than the press's first frame tick (FRAME OWNER S1B moved it from the key's own turn:
/// the press presents nothing in its turn, the first tick lays out once), and no surface may take its start size again
/// after the press.
///
/// The app's own pane content (`PaneContentView`: a tab strip over its content host) shows a real terminal
/// (`TerminalSession` with a libghostty surface), as a terminal tab does. The IO records the grids it is asked for; a
/// focus report sent after a step is a marker (`GridRecordingTerminalIO`). Frames step at a fixed 120 Hz dt, and the
/// landing's after-commit work runs when the test says (`LayoutViewContext.afterCommit`).
///
/// A structural change during a key spring lets go of every key hold (`PaneHostView.endKeyResizeHold`): a pane at rest
/// lays its content out at its rest size before the content hears it settled, and a pane the change takes over on its
/// spring lays its content out at its live size before the content hears the size the change rests at.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyboardResizeOneGridReportTests {
    /// One pane's terminal.
    struct Terminal {
        let session: TerminalSession
        let io: GridRecordingTerminalIO
        var surface: TerminalSurfaceView { session.surfaceView }
    }

    /// Each pane shows the app's pane content with a terminal in it.
    final class Panes: LayoutPaneContentProvider {
        /// Every launch region ready: nothing is held for launch, the content shows at once.
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var terminals: [PaneID: Terminal] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let io = GridRecordingTerminalIO()
            let session = TerminalSession(io: io)
            let view = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("terminal"), title: "zsh")]), reveal: reveal)
            view.show(session.view)
            terminals[pane] = Terminal(session: session, io: io)
            return view
        }
    }

    /// Every size a view takes from now on, in order: its frame-change notifications, read in the setter's own call.
    final class SizeLog {
        private(set) var sizes: [CGSize] = []
        private var observation: MainActorObservation?

        init(_ view: NSView) {
            view.postsFrameChangedNotifications = true
            observation = MainActorObservation(NSView.frameDidChangeNotification, object: view, atOnce: true,
                                               read: { ($0.object as? NSView)?.frame.size }) { [weak self] size in
                if let size { self?.sizes.append(size) }
            }
        }
    }

    /// p1 | p2.
    static let pair: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// p1 over p2.
    static let stack: SplitNode = .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// p1 beside p2 over p3.
    static let besideStack: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                               b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// `tree` in one column, a terminal in each pane, p2 focused; the test is the clock.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let panes: [PaneID]
        /// The work the landings left for after their frames' commits, run when the test says (``commit()``).
        var afterCommit: [@MainActor () -> Void] = []

        init(_ tree: SplitNode) throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: tree)]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            panes = tree.panes
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
            for pane in panes {
                let terminal = try #require(provider.terminals[pane], "\(pane) shows no terminal")
                try #require(terminal.surface.surface != nil, "libghostty created no surface for \(pane)")
                try #require(terminal.surface.isShown, "\(pane)'s terminal is not shown in its pane")
            }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        func terminal(_ pane: PaneID) throws -> Terminal { try #require(provider.terminals[pane]) }

        /// The grids `pane`'s terminal asked its PTY for since the last call.
        func grids(_ pane: PaneID) async throws -> [TerminalGridSize] {
            let terminal = try terminal(pane)
            terminal.surface.bridge.takeUnretainedValue().input.focusGained()
            return await terminal.io.gridsUntilMarker()
        }

        /// Steps 120 Hz frames until nothing moves (at most 2 s), the window laid out after each; the frame count. What a
        /// landing leaves for after its frame's commit waits for ``commit()``.
        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                frames += 1
            }
            root.layoutSubtreeIfNeeded()
            return frames
        }

        /// The landing frames' commits: the work they left runs, then the window's next layout pass.
        func commit() {
            let work = afterCommit
            afterCommit.removeAll()
            for item in work { item() }
            root.layoutSubtreeIfNeeded()
        }

        func close() {
            for terminal in provider.terminals.values {
                terminal.session.close()
                terminal.io.finish()
            }
            window.closeAfterTest()
        }
    }

    /// Ctrl-Shift-H, L, K or J on p2 (`resizePaneLeft`, `resizePaneRight`, `resizePaneUp`, `resizePaneDown`): one
    /// terminal grows, the other shrinks.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressSendsEachTerminalOnlyItsFinalGridAndNoSurfaceTakesItsStartSizeAgain(direction: LayoutDirection) async throws {
        let rig = try Rig(direction == .left || direction == .right ? Self.pair : Self.stack)
        defer { rig.close() }
        // The launch's grids (the first layout) are not this press's.
        for pane in rig.panes { _ = try await rig.grids(pane) }
        var start: [PaneID: (size: CGSize, grid: TerminalGridSize?)] = [:]
        var logs: [PaneID: SizeLog] = [:]
        for pane in rig.panes {
            let surface = try rig.terminal(pane).surface
            start[pane] = (surface.frame.size, surface.fittedGrid)
            logs[pane] = SizeLog(surface)
        }

        // The key's turn, then the press's first frame tick (the final grids go there, no later).
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(try rig.screen.holdsContentForKeyResize, "the press did not hold the pane contents (K3)")
        #expect(rig.root.advanceFrame(1.0 / 120), "the press did not spring")
        rig.root.layoutSubtreeIfNeeded()
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in rig.panes { atPress[pane] = try await rig.grids(pane) }

        // The spring to its landing frame.
        let frames = rig.settle()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        // After the landing frame's commit: the held contents are let go (K3), then the next layout pass.
        #expect(!rig.afterCommit.isEmpty, "the landing left no release for after its commit: no key-resize hold ran")
        rig.commit()

        for pane in rig.panes {
            let terminal = try rig.terminal(pane)
            let atLanding = try await rig.grids(pane)
            let before = try #require(start[pane])
            let final = try #require(terminal.surface.fittedGrid, "\(pane)'s terminal fits no grid")
            let sizes = try #require(logs[pane]).sizes
            let startGrid = before.grid.map { "\($0)" } ?? "none"
            #expect(final != before.grid, "the press did not change \(pane)'s grid (\(final))")
            #expect(atPress[pane] == [final], "\(pane): up to its first frame the press asked the PTY for \(atPress[pane] ?? []), not the final grid \(final)")
            #expect(atLanding.isEmpty,
                    "\(pane): after the final grid \(final) at the press, the landing asked the PTY for \(atLanding) (start grid \(startGrid))")
            #expect(!sizes.contains(before.size), "\(pane): the surface took its start size \(before.size) again after the press: \(sizes)")
            // At rest the surface fills its host again (no hold left).
            let host = terminal.session.view
            #expect(terminal.surface.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                    "\(pane): the surface rests at \(terminal.surface.frame.size) in a \(host.bounds.size) host")
        }
    }

    /// A close during a second key press lets go of both key holds (`PaneHostView.endKeyResizeHold`). The first press's
    /// landing frame commits, and lets go of what it held, when the run loop next waits; input that comes first runs
    /// before that: a second press (Ctrl-Shift-J) springs the panes beside the first one, and a close arrives during that
    /// spring. p1 is at rest: its terminal sends no grid after the final one of the first press, and its surface never
    /// takes its start size again. p2 is on the second press's spring, which the close takes over: its terminal sends one
    /// grid for the close, the final one, measured from its live size (not from the size its key hold kept).
    /// Only the pane's content area holds (FRAME OWNER S1): the pane content view, its tab strip with it, follows the pane.
    @Test func aCloseDuringASecondPressSendsEachTerminalOnlyItsFinalGrid() async throws {
        let rig = try Rig(Self.besideStack)
        defer { rig.close() }
        for pane in rig.panes { _ = try await rig.grids(pane) }
        let terminal = try rig.terminal("p1")
        let start = (size: terminal.surface.frame.size, grid: terminal.surface.fittedGrid)
        let log = SizeLog(terminal.surface)

        // Ctrl-Shift-L on p1: p1 grows, p2 and p3 shrink; its first frame sends p1's final grid. The spring lands; its
        // release waits for that frame's commit.
        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(rig.root.advanceFrame(1.0 / 120), "the first press did not spring")
        rig.root.layoutSubtreeIfNeeded()
        let atPress = try await rig.grids("p1")
        #expect(rig.settle() > 3, "the first press did not spring")
        let host = try #require(rig.root.context.hosts["p1"])
        let area = try #require((host.content as? PaneContentView)?.contentHost)
        try #require(!host.isOnLayoutSpring && host.content.frame.size == host.contentRect.size && area.isHolding,
                     "p1 is not at rest with its content area held (\(host.content.frame.size) in \(host.contentRect.size), area holding \(area.isHolding))")

        // Before that commit: Ctrl-Shift-J on p2 springs p2 and p3 (p1 stays at rest), and p3 closes during its spring.
        #expect(PaneResize.press("p2", .down, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(try rig.screen.holdsContentForKeyResize, "the second press did not hold the pane contents (K3)")
        for frame in 1...6 {
            #expect(rig.root.advanceFrame(1.0 / 120), "the second press landed after \(frame) frames")
            rig.root.layoutSubtreeIfNeeded()
        }
        #expect(!host.isOnLayoutSpring, "the second press moved p1")
        let p2 = try rig.terminal("p2")
        try #require(rig.root.context.hosts["p2"]?.isOnLayoutSpring == true, "p2 is not on the second press's spring when p3 closes")
        // What p2 asked for up to the close (the final grids of both presses) is not the close's.
        _ = try await rig.grids("p2")
        let layout = try #require(rig.model.screen(containing: "p1")?.layout)
        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.closing("p3", in: layout))])
        rig.root.syncWithModel()
        rig.settle()
        rig.commit()

        let final = try #require(terminal.surface.fittedGrid, "p1's terminal fits no grid")
        let after = try await rig.grids("p1")
        let startGrid = start.grid.map { "\($0)" } ?? "none"
        #expect(final != start.grid, "the first press did not change p1's grid (\(final))")
        #expect(atPress == [final], "up to its first frame the first press asked p1's PTY for \(atPress), not the final grid \(final)")
        #expect(after.isEmpty, "p1: after the final grid \(final) at the first press, letting its content go asked the PTY for \(after) (start grid \(startGrid))")
        #expect(!log.sizes.contains(start.size), "p1's surface took its start size \(start.size) again after the first press: \(log.sizes)")
        #expect(host.content.frame.size == host.contentRect.size && !area.isHolding,
                "p1's content is not at its rest size: \(host.content.frame.size) in \(host.contentRect.size), area holding \(area.isHolding)")

        let p2Final = try #require(p2.surface.fittedGrid, "p2's terminal fits no grid")
        let p2Grids = try await rig.grids("p2")
        #expect(p2Grids == [p2Final], "p2: the close that took over its key spring asked the PTY for \(p2Grids), not its final grid \(p2Final) once")
        let p2Host = p2.session.view
        #expect(p2.surface.frame.size == p2Host.surfaceSize(forHostSize: p2Host.bounds.size),
                "p2's surface rests at \(p2.surface.frame.size) in a \(p2Host.bounds.size) host")
    }

    /// `layout` with `pane` closed and every other split kept: its sibling takes its split's place.
    static func closing(_ pane: PaneID, in layout: ScreenLayout) -> ScreenLayout {
        guard case .columns(let columns) = layout else { return layout }
        return .columns(columns.map { column in
            var column = column
            column.root = removing(pane, from: column.root) ?? column.root
            return column
        })
    }

    static func removing(_ pane: PaneID, from node: SplitNode) -> SplitNode? {
        switch node {
        case .leaf(let leaf):
            return leaf == pane ? nil : node
        case let .split(id, axis, ratio, a, b):
            guard let kept = removing(pane, from: a) else { return b }
            guard let other = removing(pane, from: b) else { return kept }
            return .split(id, axis: axis, ratio: ratio, a: kept, b: other)
        }
    }
}
