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
/// grid, the final one, at the press, and no surface may take its start size again after the press.
///
/// The app's own pane content (`PaneContentView`: a tab strip over its content host) shows a real terminal
/// (`TerminalSession` with a libghostty surface), as a terminal tab does. The IO records the grids it is asked for; a
/// focus report sent after a step is a marker (`GridRecordingTerminalIO`). Frames step at a fixed 120 Hz dt, and the
/// landing's after-commit work runs when the test says (`LayoutViewContext.afterCommit`).
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

    /// p1 | p2 (or p1 over p2) in one column, a terminal in each, p2 focused; the test is the clock.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The work the landing left for after its frame's commit, run when the test says.
        var afterCommit: [@MainActor () -> Void] = []

        init(axis: SplitAxis) throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
            for pane in Self.panes {
                let terminal = try #require(provider.terminals[pane], "\(pane) shows no terminal")
                try #require(terminal.surface.surface != nil, "libghostty created no surface for \(pane)")
                try #require(terminal.surface.isShown, "\(pane)'s terminal is not shown in its pane")
            }
        }

        static let panes: [PaneID] = ["p1", "p2"]

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        func terminal(_ pane: PaneID) throws -> Terminal { try #require(provider.terminals[pane]) }

        /// The grids `pane`'s terminal asked its PTY for since the last call.
        func grids(_ pane: PaneID) async throws -> [TerminalGridSize] {
            let terminal = try terminal(pane)
            terminal.surface.bridge.takeUnretainedValue().input.focusGained()
            return await terminal.io.gridsUntilMarker()
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
        let rig = try Rig(axis: direction == .left || direction == .right ? .horizontal : .vertical)
        defer { rig.close() }
        // The launch's grids (the first layout) are not this press's.
        for pane in Rig.panes { _ = try await rig.grids(pane) }
        var start: [PaneID: (size: CGSize, grid: TerminalGridSize?)] = [:]
        var logs: [PaneID: SizeLog] = [:]
        for pane in Rig.panes {
            let surface = try rig.terminal(pane).surface
            start[pane] = (surface.frame.size, surface.fittedGrid)
            logs[pane] = SizeLog(surface)
        }

        // The key's turn.
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(try rig.screen.holdsContentForKeyResize, "the press did not hold the pane contents (K3)")
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in Rig.panes { atPress[pane] = try await rig.grids(pane) }

        // The spring to its landing frame.
        var frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            rig.root.layoutSubtreeIfNeeded()
            frames += 1
        }
        rig.root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        // After the landing frame's commit: the held contents are let go (K3), then the next layout pass.
        #expect(!rig.afterCommit.isEmpty, "the landing left no release for after its commit: no key-resize hold ran")
        let release = rig.afterCommit
        rig.afterCommit.removeAll()
        for work in release { work() }
        rig.root.layoutSubtreeIfNeeded()

        for pane in Rig.panes {
            let terminal = try rig.terminal(pane)
            let atLanding = try await rig.grids(pane)
            let before = try #require(start[pane])
            let final = try #require(terminal.surface.fittedGrid, "\(pane)'s terminal fits no grid")
            let sizes = try #require(logs[pane]).sizes
            let startGrid = before.grid.map { "\($0)" } ?? "none"
            #expect(final != before.grid, "the press did not change \(pane)'s grid (\(final))")
            #expect(atPress[pane] == [final], "\(pane): the key's turn asked the PTY for \(atPress[pane] ?? []), not the final grid \(final)")
            #expect(atLanding.isEmpty,
                    "\(pane): after the final grid \(final) at the press, the landing asked the PTY for \(atLanding) (start grid \(startGrid))")
            #expect(!sizes.contains(before.size), "\(pane): the surface took its start size \(before.size) again after the press: \(sizes)")
            // At rest the surface fills its host again (no hold left).
            let host = terminal.session.view
            #expect(terminal.surface.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                    "\(pane): the surface rests at \(terminal.surface.frame.size) in a \(host.bounds.size) host")
        }
    }
}
