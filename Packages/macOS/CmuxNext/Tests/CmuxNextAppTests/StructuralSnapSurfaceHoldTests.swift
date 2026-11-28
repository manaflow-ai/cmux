import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// cmuxterm-hq#19032 cause 1 (fleet job 9c35cd0a, half-empty `move_to_split_right`): a structural change that snaps (a
/// split, a pane moved to a new split) showed one committed frame with each resized terminal's surface layer already at
/// its new size inside its pane at the old one (terminal 1: layer and IOSurface 456 wide in its 684-wide pane), then the
/// panes a frame later. `ScreenContentView+SnapFrame`: the screen keeps showing what it showed until a frame tick shows
/// the change, so a terminal's layer must be at its host's area size in every commit: the old one until the tick that
/// shows the change, the new one from it (FRAME OWNER S4: bounds change only with the frame drawn at them).
///
/// p1 | p2 | p3, each a terminal in the app's `PaneContentView`, in a window on screen, the frames stepped by the test.
/// The change splits p3 (p4 new, empty), or moves p3's terminal into the new p4 in the change's turn. Every commit
/// from the change's turn to 4 stepped frames after it is read.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct StructuralSnapSurfaceHoldTests {
    @Test(arguments: [false, true])
    func eachCommitOfASnappedSplitShowsEachTerminalAtItsHostsSize(moving: Bool) async throws {
        let screen = try await ReduceMotionPaneCloseFrameTests.ThreePanes(reduceMotion: false)
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        defer {
            presenter.placeHook = nil
            screen.close()
        }
        let names = ["p1", "p2", "p3"]
        var label = "before"
        presenter.placeHook = { view, frame in
            guard frame.size != view.bounds.size, let index = screen.sessions.firstIndex(where: { $0.surfaceView === view }) else { return }
            let stack = Thread.callStackSymbols.dropFirst(1).prefix(14).joined(separator: "\n    ")
            print("SNAP HOLD place \(label) \(names[index]): \(Self.text(view.bounds.size)) -> \(Self.text(frame.size))\n    \(stack)")
        }
        let tree = SplitNode.split("x", axis: .horizontal, ratio: 0.25, a: .leaf("p1"),
                                   b: .split("y", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p2"),
                                             b: .split("z", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))))
        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: 1, root: tree)]))])
        label = "change"
        screen.root.syncWithModel()
        if moving {
            let target = try #require(screen.provider.views["p4"], "the split made no content for p4")
            _ = target.show(screen.sessions[2].view)
        }
        var off: [String] = []
        func read(_ label: String) {
            for (index, session) in screen.sessions.enumerated() {
                let view = session.surfaceView, host = session.view
                guard host.window != nil, !host.isHiddenOrHasHiddenAncestor else { continue }
                let area = host.surfaceSize(forHostSize: host.bounds.size), layer = view.layer?.bounds.size ?? .zero
                let shown = host.convert(host.bounds, to: nil)
                let scale = view.layer?.contentsScale ?? 2
                let line = "\(label) \(names[index]): host \(Self.text(shown)), area \(Self.text(area)), layer \(Self.text(layer)), "
                    + "presenter \(presenter.debugState(of: view)), wanted \(view.frameOwnership.wanted.map { Self.text($0.size) } ?? "none"), "
                    + "in flight \(view.frameOwnership.inFlight.map(Self.text) ?? "none"), ahead \(view.frameOwnership.ahead.map(Self.text) ?? "none"), "
                    + "pending ahead \(view.frameOwnership.pendingAhead.map(Self.text) ?? "none")"
                print("SNAP HOLD \(line)")
                // A layer at another size than its host's area shows the new size in the old pane, or the old in the new.
                // Moved into a pane that has no size yet (0x0), nothing of it shows.
                guard area.width >= 1, area.height >= 1 else { continue }
                if abs(layer.width - area.width) * scale > 1 || abs(layer.height - area.height) * scale > 1 { off.append(line) }
            }
        }
        for commit in 0..<6 {
            label = "commit \(commit)"
            await TerminalKeyResizeFrameTests.commit()
            read(label)
        }
        for frame in 1...4 {
            label = "frame \(frame)"
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
            read(label)
            for extra in 0..<3 {
                label = "frame \(frame) commit \(extra)"
                await TerminalKeyResizeFrameTests.commit()
                read(label)
            }
        }
        #expect(off.isEmpty, "\(off.count) commits showed a terminal's layer at another size than its host's area: \(off)")
    }

    static func text(_ size: CGSize) -> String { "\(size.width)x\(size.height)" }
    static func text(_ rect: CGRect) -> String { "(\(rect.minX),\(rect.minY) \(rect.width)x\(rect.height))" }
}
