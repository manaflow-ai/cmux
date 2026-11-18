import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// CLOSE MOTION fix 3 (film cm-b-split-reduce, before build 07d733efa6af, 120 Hz): under Reduce Motion a pane close
/// jumps to its final layout in one frame, but that frame (+24 ms) showed the terminal left of the closed pane still at
/// its old width and the one right of it at its final x but its old width, the terminal ground in the rest; the final
/// layout showed one refresh later (+33 ms). The jump laid the panes out in the close's own turn, so each terminal asked
/// Ghostty for its new size there, and the pass just before that turn's commit found no frame drawn at it (FRAME OWNER
/// S4 keeps the old bounds and frame until then). T-KEYS 3 (f801ff735f5) gave the first refresh of a key spring its size
/// ahead; a jump had none. The Chromium model: the renderer gets the size before the compositor needs its frame.
///
/// p1 | p2 | p3, each the app's `PaneContentView` with a terminal, in a window on screen, Reduce Motion on, the frames
/// stepped by the test. Close p2 as `PaneController.showPaneClose` does (`LayoutModel.showPaneClose`, then the view
/// syncs with the model in the close's turn). Each commit from the close's turn to the first stepped frame is read, per
/// terminal still shown: when its host's area is no longer the one it had before the close, its surface layer must be at
/// that area's size (within 1 device px) and its presenter must hold no request. The renderer gets the time the app
/// gives it before the next refresh (here: until each size drawn ahead is drawn, at most 1 s). The close must show by
/// the first stepped frame.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct ReduceMotionPaneCloseFrameTests {
    @Test func theFirstFrameAfterAReduceMotionPaneCloseShowsEachTerminalAtItsPanesSize() async throws {
        let screen = try await ThreePanes()
        defer { screen.close() }
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        let kept = [0, 2]
        let start = kept.map { screen.sessions[$0].view.surfaceSize(forHostSize: screen.sessions[$0].view.bounds.size) }

        let reports = TerminalSurfaceView.gridReports
        try #require(screen.model.showPaneClose("p2") != nil, "the close of p2 was not shown")
        screen.root.syncWithModel()
        var off: [String] = []
        var moved = 0
        func read(_ label: String) {
            for (index, terminal) in kept.enumerated() {
                let session = screen.sessions[terminal], view = session.surfaceView, host = session.view
                let area = host.surfaceSize(forHostSize: host.bounds.size), layer = view.layer?.bounds.size ?? .zero
                let scale = view.layer?.contentsScale ?? 2
                let line = "\(label) p\(terminal + 1): area \(Self.text(area)) (before the close \(Self.text(start[index]))), "
                    + "layer \(Self.text(layer)), presenter \(presenter.debugState(of: view)), "
                    + "in flight \(view.frameOwnership.inFlight.map(Self.text) ?? "none"), ahead \(view.frameOwnership.ahead.map(Self.text) ?? "none")"
                print("CLOSE MOTION 3 \(line)")
                guard area != start[index] else { continue }
                moved += 1
                if presenter.isWaiting(view) || abs(layer.width - area.width) * scale > 1 || abs(layer.height - area.height) * scale > 1 {
                    off.append(line)
                }
            }
        }
        await TerminalKeyResizeFrameTests.commit() // the close's turn: its presenter pass, then its commit
        read("the close's commit")
        _ = await Self.commits(screen, seconds: 1) { screen in
            kept.allSatisfy { terminal in
                let view = screen.sessions[terminal].surfaceView, state = view.hostFrame(present: false)
                return view.frameOwnership.ahead == nil || state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_SHOWN
            }
        }
        // A snap's size drawn ahead is render only: its grid goes when the snap shows (review of #38125, finding 1: the key
        // press's rule, its grid with the size drawn ahead, reached the snap and sent each terminal's grid in the close's turn).
        #expect(TerminalSurfaceView.gridReports == reports,
                "a Reduce Motion close sent \(TerminalSurfaceView.gridReports - reports) grids before it showed: a snap's grid goes at its landing")
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        await TerminalKeyResizeFrameTests.commit()
        read("the first frame")
        try #require(moved > 0, "no terminal's area changed by the first frame: the close did not show")
        #expect(off.isEmpty, "\(off.count) committed frames showed a terminal not at its pane's size after a Reduce Motion close: \(off)")
    }

    static func text(_ size: CGSize) -> String { "\(size.width)x\(size.height)" }

    /// Commits until `done` holds (checked before each commit, at most `seconds`), with no frame tick between.
    static func commits(_ screen: ThreePanes, seconds: Int, until done: (ThreePanes) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !done(screen) {
            guard ContinuousClock.now < deadline else { return false }
            await TerminalKeyResizeFrameTests.commit()
        }
        return true
    }

    /// p1 | p2 | p3 in a window on screen, each pane the app's `PaneContentView` with a terminal in its content area;
    /// Reduce Motion on, even split sizing, the frames stepped by the test.
    final class ThreePanes {
        let provider = TerminalKeyResizeFrameTests.PaneScreen.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var sessions: [TerminalSession] = []
        var ios: [ScriptedTerminalIO] = []
        private let drew: Bool

        /// `reduceMotion`: false pins pane springs on (a key press animates), for the same three terminals.
        init(reduceMotion: Bool = true) async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            let tree = SplitNode.split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                        b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: 1, root: tree)]))],
                                activeScreenID: "s", focusedPane: "p2")
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded() // sync-layout: the panes exist before their terminals attach
            root.layoutSubtreeIfNeeded() // sync-layout: what joined the window in that pass lays out in this one
            root.driver.isManual = true
            let line = String(repeating: "y", count: 40)
            let text = Array(repeating: line, count: 400).joined(separator: "\r\n")
            for pane: PaneID in ["p1", "p2", "p3"] {
                let io = ScriptedTerminalIO()
                let session = TerminalSession(io: io)
                ios.append(io)
                guard session.surfaceView.surface != nil, let content = provider.views[pane] else {
                    close()
                    try #require(Bool(false), "libghostty created no surface, or pane \(pane) has no content")
                    return
                }
                _ = content.show(session.view)
                content.layoutSubtreeIfNeeded() // sync-layout: the attach's own layout pass
                io.send(.output(Data(text.utf8)))
                sessions.append(session)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, sessions.contains(where: { $0.surfaceView.presentedFrame == nil }) {
                await TerminalKeyResizeFrameTests.commit()
            }
            let drawn = !sessions.contains { $0.surfaceView.presentedFrame == nil }
            if !drawn { close() }
            try #require(drawn, "a terminal never showed its first frame")
            // At rest before the close: the panes and their terminals have not changed for 300 ms (at most 3 s).
            let rest = ContinuousClock.now.advanced(by: .seconds(3))
            var last: [CGSize] = [], changed = ContinuousClock.now
            while ContinuousClock.now < rest, changed.duration(to: .now) < .milliseconds(300) {
                await TerminalKeyResizeFrameTests.commit()
                let now = sessions.flatMap { [$0.view.bounds.size, $0.surfaceView.layer?.bounds.size ?? .zero] }
                if now != last { (last, changed) = (now, .now) }
            }
        }

        func close() {
            root.driver.isManual = false
            for io in ios { io.finish() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        }
    }
}
