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

/// CLOSE MOTION fix 3 (film cm-b-split-reduce, 120 Hz): under Reduce Motion a pane close jumps to its final layout in
/// one frame, and no frame may show a terminal off its pane's size. Before #37330 the jump's commit showed the terminal
/// left of the closed pane still at its old width and the one right of it at its final x but its old width.
///
/// GI RENDERER SYNC 2 (#40174) port. The snap no longer waits a frame tick for sizes drawn ahead (the draw-ahead is
/// gone): it shows in the close's own turn, as before #37330 (ghostty-integration.md 4.3: "Reduce Motion and 'no
/// animation' snap in one frame"). Each kept terminal's surface layer takes its pane's area in that same commit; its
/// frame is Ghostty's: on the primary screen the new size's frame shows when drawn, the last frame top-left until then
/// (fork tests "resize sync: the primary screen shows a frame of a new host size at once" and "host present: a frame
/// of a new host size on main is shown by default").
///
/// p1 | p2 | p3, each the app's `PaneContentView` with a terminal, in a window on screen, Reduce Motion on, the frames
/// stepped by the test. Close p2 as `PaneController.showPaneClose` does (`LayoutModel.showPaneClose`, then the view
/// syncs with the model in the close's turn). The close's commit and the first stepped frame are read, per terminal
/// still shown: when its host's area is no longer the one it had before the close, its surface layer must be at that
/// area's size (within 1 device px). Then each kept terminal shows its own frame and its PTY ends at its view's grid.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct ReduceMotionPaneCloseFrameTests {
    @Test func aReduceMotionPaneCloseShowsEachTerminalAtItsPanesSizeInItsOwnCommit() async throws {
        let screen = try await ThreePanes()
        defer { screen.close() }
        let kept = [0, 2]
        let start = kept.map { screen.sessions[$0].view.surfaceSize(forHostSize: screen.sessions[$0].view.bounds.size) }

        let gridsBefore = kept.map { screen.ios[$0].resizes.count }
        try #require(screen.model.showPaneClose("p2") != nil, "the close of p2 was not shown")
        screen.root.syncWithModel()
        var off: [String] = []
        var moved: [String: Int] = [:]
        func read(_ label: String) {
            for (index, terminal) in kept.enumerated() {
                let session = screen.sessions[terminal], view = session.surfaceView, host = session.view
                let area = host.surfaceSize(forHostSize: host.bounds.size), layer = view.layer?.bounds.size ?? .zero
                let scale = view.layer?.contentsScale ?? 2
                let line = "\(label) p\(terminal + 1): area \(Self.text(area)) (before the close \(Self.text(start[index]))), layer \(Self.text(layer))"
                print("CLOSE MOTION 3 \(line)")
                guard area != start[index] else { continue }
                moved[label, default: 0] += 1
                if abs(layer.width - area.width) * scale > 1 || abs(layer.height - area.height) * scale > 1 { off.append(line) }
            }
        }
        await TerminalKeyResizeFrameTests.commit() // the close's turn and its commit
        read("the close's commit")
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        await TerminalKeyResizeFrameTests.commit()
        read("the first frame")
        #expect((moved["the close's commit"] ?? 0) > 0, "no kept terminal's area changed in the close's own commit: the snap waited")
        #expect(off.isEmpty, "\(off.count) committed frames showed a terminal layer not at its pane's size after a Reduce Motion close: \(off)")
        let rested = await Self.commits(screen, seconds: 2) { screen in
            kept.allSatisfy { TerminalKeyResizeFrameTests.showsItsOwnFrame(screen.sessions[$0]) }
        }
        #expect(rested, "a kept terminal does not show its own frame 2 s after the close")
        let settled = await Self.commits(screen, seconds: 2) { screen in
            kept.allSatisfy { terminal in
                let view = screen.sessions[terminal].surfaceView
                let last = screen.ios[terminal].resizes.last.map { TerminalGridSize(columns: $0.columns, rows: $0.rows) }
                return view.fittedGrid != nil && last == view.fittedGrid
            }
        }
        #expect(settled, "a kept terminal's PTY does not end at its view's grid after the close")
        // At most one grid per kept terminal for the close (its landing is its first frame), counted at the kept
        // terminals' own PTYs. `TerminalSurfaceView.gridReports` counts every terminal of the process, and the terminals
        // of the suites that run beside this one report in the awaits above (red at 35f0e356de2d beside 10 other suites:
        // 8 reports counted; green alone). A grid reaches its IO through the ordered input stream, so the count is read
        // after a marker that goes through that stream behind every grid asked for so far (``gridsReachedTheirPTYs``):
        // it is every grid of the close, the first frame's included, also one more that follows the final grid.
        let reached = await Self.gridsReachedTheirPTYs(screen, kept)
        try #require(reached, "a kept terminal's input stream did not reach its PTY in 2 s")
        let sent = zip(kept, gridsBefore).map { screen.ios[$0].resizes.count - $1 }
        #expect(sent.allSatisfy { $0 <= 1 }, "a Reduce Motion close sent \(sent) grids to the \(kept.count) resized terminals: at most one each")
    }

    static func text(_ size: CGSize) -> String { "\(size.width)x\(size.height)" }

    /// Whether every grid that `terminals` asked their PTYs for so far is in their `ScriptedTerminalIO.resizes` (at most
    /// 2 s). A grid goes to its IO through the session's ordered input stream, and the IO records it in the stream's
    /// consumer task: a count read at the first moment the PTY has its view's grid can miss a grid that follows it
    /// ("final, stale, final"). So each terminal sends its coalesced grid now (`gridReports.flush()`), then marker
    /// bytes through the same stream; when the IO has the marker, it has every grid sent before it.
    static func gridsReachedTheirPTYs(_ screen: ThreePanes, _ terminals: [Int]) async -> Bool {
        let marker = Data("grids-read-\(UUID().uuidString)".utf8)
        for terminal in terminals {
            let view = screen.sessions[terminal].surfaceView
            view.gridReports.flush()
            view.bridge.takeUnretainedValue().input.send(marker)
        }
        return await commits(screen, seconds: 2) { screen in
            terminals.allSatisfy { screen.ios[$0].writes.contains(marker) }
        }
    }

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
