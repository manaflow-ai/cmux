import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextSignposts
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// FRAME OWNER REFACTOR S4, defect (a) before the switch goes on by default (films ab-s4d-sw-22 on build 645ad29d,
/// px-row-drag-3r, judge v7): in a row divider drag, the lower terminal's content edge lagged its pane's moving top edge
/// by 2 refreshes with `motion.frameOwner.terminals` on (-4 px in 2 px drag steps, 156 of 667 frames), against 1 refresh
/// with it off (-2 px, 117 of 676). A drag holds each surface at its start size (``TerminalDragTunables``
/// `holdsSurfaceDuringDrag`), so only the surface's origin moves; the content's top edge is its layer's top edge.
///
/// The real path, in a window on screen: p1 above p2 in a ``LayoutRootView``, a terminal in each, and the app's divider
/// drag (`ScreenContentView.handleDrag`), one pointer move of 2 pt per refresh of the window's display link, first with
/// the switch off, then on. After each Core Animation commit it reads, in the committed layer tree, p2's pane host top
/// edge and its surface layer's top edge. At rest their distance is constant; in a drag every refresh where it differs
/// is a refresh the content lags its pane. With the switch on that count and the largest gap may not exceed off's.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`). (A first version
/// resized a bare terminal from a display-link tick and saw no lag with the switch on or off, so the lag is on the
/// layout path.)
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalFrameOwnerDragCadenceTests {
    typealias KeyScreen = TerminalSurfaceCommitSizeTests.KeyScreen

    @Test func aRowDragMovesTheTerminalWithItsPaneEdgeNoLaterWithTheSwitchOnThanOff() async throws {
        let rig = try await RowDragRig()
        defer { rig.close() }
        TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(false))
        await rig.commits(4)
        let off = await rig.drag(by: 2, steps: 50)
        TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(true))
        await rig.commits(4)
        let on = await rig.drag(by: -2, steps: 50)
        let summary = "off: \(off); on: \(on)"
        print("S4 row drag: \(summary)")
        try #require(off.samples >= 30 && on.samples >= 30, "too few refreshes were sampled: \(summary)")
        try #require(off.paneMoved && on.paneMoved, "the pane edge did not move in a drag: \(summary)")
        #expect(on.lagging <= off.lagging,
                "with the switch on the terminal's top edge differs from its pane's in \(on.lagging) refreshes, off in \(off.lagging): \(summary)")
        #expect(on.largestGap <= off.largestGap,
                "with the switch on the largest gap is \(on.largestGap) pt, off \(off.largestGap) pt: \(summary)")
    }

    /// p1 above p2, a terminal in each, in a window on screen; a sampler after each Core Animation commit.
    @MainActor final class RowDragRig {
        struct Run: CustomStringConvertible {
            /// The gap (surface top - pane top - the rest gap, points) after each commit of the drag.
            var gaps: [Double]
            var paneMoved: Bool
            var samples: Int { gaps.count }
            var lagging: Int { gaps.filter { abs($0) > 0.25 }.count }
            var largestGap: Double { gaps.map(abs).max() ?? 0 }
            var description: String {
                "\(lagging) of \(samples) refreshes off, largest \(largestGap) pt, gaps " +
                    gaps.map { String(format: "%.1f", $0) }.joined(separator: " ")
            }
        }

        let provider = KeyScreen.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var sessions: [TerminalSession] = []
        var ios: [ScriptedTerminalIO] = []
        private let drew: Bool
        private var sampler: MainRunLoopObserver?
        private var recording: [Double]?
        private var paneTops: [Double] = []
        private var restGap: Double?

        init() async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            let tree: SplitNode = .split("r", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded() // sync-layout: the panes exist before their terminals attach
            let line = String(repeating: "z", count: 40)
            let text = Array(repeating: line, count: 200).joined(separator: "\r\n")
            for pane: PaneID in ["p1", "p2"] {
                let io = ScriptedTerminalIO()
                let session = TerminalSession(io: io)
                ios.append(io)
                guard session.surfaceView.surface != nil, let container = provider.containers[pane] else {
                    close()
                    try #require(Bool(false), "libghostty created no surface, or pane \(pane) has no container")
                    return
                }
                session.view.frame = container.bounds
                session.view.autoresizingMask = [.width, .height]
                container.addSubview(session.view)
                session.view.layoutSubtreeIfNeeded() // sync-layout: the attach's own layout pass
                io.send(.output(Data(text.utf8)))
                sessions.append(session)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, sessions.contains(where: { $0.surfaceView.presentedFrame == nil }) {
                await commits(1)
            }
            let drawn = !sessions.contains { $0.surfaceView.presentedFrame == nil }
            if !drawn { close() }
            try #require(drawn, "a terminal never showed its first frame")
            sampler = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                          drawsNothingAfterCommit: true) { [weak self] _ in self?.sample() }
        }

        func close() {
            sampler = nil
            for io in ios { io.finish() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, nil)
        }

        /// p2's pane host and its surface layer, top edges in the window's root layer (committed model values).
        private func tops() -> (pane: Double, surface: Double)? {
            guard let screen = root.screenViews["s"], let rootLayer = root.layer,
                  let paneHost = screen.subviews.compactMap({ $0 as? PaneHostView }).first(where: { $0.pane == "p2" }),
                  let paneLayer = paneHost.layer, sessions.count == 2,
                  let surfaceLayer = sessions[1].surfaceView.layer else { return nil }
            let pane = paneLayer.convert(paneLayer.bounds, to: rootLayer)
            let surface = surfaceLayer.convert(surfaceLayer.bounds, to: rootLayer)
            // The root layer's y grows up unless its geometry is flipped: the top edge is the larger y then.
            let flipped = rootLayer.isGeometryFlipped || root.isFlipped
            return flipped ? (Double(pane.minY), Double(surface.minY)) : (Double(pane.maxY), Double(surface.maxY))
        }

        private func sample() {
            guard recording != nil, let tops = tops(), let rest = restGap else { return }
            recording?.append((tops.surface - tops.pane) - rest)
            paneTops.append(tops.pane)
        }

        /// One drag of p1|p2's divider, `steps` moves of `step` points, one per refresh; returns the gaps it sampled.
        func drag(by step: CGFloat, steps: Int) async -> Run {
            guard let screen = root.screenViews["s"], let handle = screen.dividerViews[.split("r")],
                  let rest = tops() else { return Run(gaps: [], paneMoved: false) }
            restGap = rest.surface - rest.pane
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            screen.handleDrag(kind: .split("r"), event: .began(start, []))
            recording = []
            paneTops = []
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var moved = 0
                var finished: CheckedContinuation<Void, Never>? = done
                let client = FrameClient(owner: "test.terminalRowDrag", isAnimation: false,
                                         scheduler: { [window] in FrameScheduler.forWindow(window) }) { _ in
                    guard moved < steps else {
                        finished?.resume()
                        finished = nil
                        return false
                    }
                    moved += 1
                    screen.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x, y: start.y + step * CGFloat(moved)), []))
                    return true
                }
                client.activate()
                self.dragClient = client
            }
            dragClient = nil
            let gaps = recording ?? []
            let moved = Set(paneTops.map { ($0 * 2).rounded() }).count > 2
            recording = nil
            screen.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x, y: start.y + step * CGFloat(steps)), []))
            await commits(30)
            return Run(gaps: gaps, paneMoved: moved)
        }

        private var dragClient: FrameClient?

        /// Returns after `count` main run-loop turns ended with a Core Animation commit.
        func commits(_ count: Int) async {
            for _ in 0..<count {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CommitBoundary().after { _ in done.resume() }
                }
            }
        }
    }
}
