import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// FRAME OWNER REFACTOR S4, defect (a) before the switch goes on by default (films ab-s4d-sw-22 on build 645ad29d,
/// px-row-drag-3r, judge v7): in a divider drag, the terminal's content edge lagged its pane edge by 2 refreshes with
/// `motion.frameOwner.terminals` on (p2's moving edge -4 px per 2 px drag step, in 156 of 667 frames), against 1 refresh
/// with it off (-2 px, 117 of 676). A drag gives a terminal one new size per display refresh.
///
/// This drags a real Ghostty surface one size per refresh of its window's display link (a ``FrameClient`` on the window's
/// ``FrameScheduler``, as a drag's events come once per refresh), first with the switch off and then on. At each refresh
/// it reads how many refreshes old the size of the frame the terminal shows is. On may not be later than off. With the
/// switch on it also counts Ghostty's state of the frame for the newest size at each refresh (READY: drawn and not
/// presented yet; PENDING: not drawn yet), which says where a late refresh goes.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalFrameOwnerDragCadenceTests {
    typealias Fixture = TerminalSurfaceCommitSizeTests.Fixture

    @Test func aDragShowsEachSizeNoLaterWithTheSwitchOnThanOff() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        // The fixture starts with the switch on; the off run comes first, as in the films.
        TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(false))
        await fixture.commits(3)
        let off = await DragRun(fixture: fixture, from: 600, step: -2, steps: 60).run()
        let rested = await fixture.waitShown(width: 482)
        try #require(rested, "the off drag's last size never showed")

        TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(true))
        await fixture.commits(3)
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        let before = presenter.stats
        let on = await DragRun(fixture: fixture, from: 482, step: 2, steps: 60).run()
        let after = presenter.stats
        let stats = "presented \(after.presented - before.presented), keeps \(after.keeps - before.keeps), " +
            "group waits \(after.groupWaits - before.groupWaits), fallbacks \(after.fallbacks - before.fallbacks), " +
            "passes \(after.passes - before.passes)"
        let summary = "off: \(off); on: \(on); presenter: \(stats)"
        print("S4 drag cadence: \(summary)")
        try #require(off.lags.count >= 30 && on.lags.count >= 30, "too few refreshes were sampled: \(summary)")
        #expect(on.median <= off.median,
                "with the switch on the frame shown is \(on.median) refreshes old at the median, off \(off.median): \(summary)")
        #expect(on.p95 <= off.p95, "p95: on \(on.p95) refreshes, off \(off.p95): \(summary)")
    }

    /// One drag: a new terminal width at each refresh of the window's display link.
    @MainActor final class DragRun {
        struct Result: CustomStringConvertible {
            var lags: [Int]
            /// Ghostty's frame state for the newest size, at each refresh (switch on: the presenter's view of it).
            var states: [String: Int]
            var median: Int { lags.isEmpty ? -1 : lags.sorted()[lags.count / 2] }
            var p95: Int { lags.isEmpty ? -1 : lags.sorted()[min(lags.count - 1, Int(Double(lags.count) * 0.95))] }
            var description: String {
                "median \(median), p95 \(p95), max \(lags.max() ?? -1) refreshes old over \(lags.count) refreshes " +
                    "(\(lags.map(String.init).joined(separator: " "))); frame states \(states.sorted { $0.key < $1.key })"
            }
        }

        private let fixture: Fixture
        private let widths: [CGFloat]
        /// The width asked at each refresh so far, in pixels.
        private var wanted: [Int] = []
        private var lags: [Int] = []
        private var states: [String: Int] = [:]
        private var client: FrameClient?
        private var finished: CheckedContinuation<Void, Never>?

        init(fixture: Fixture, from: CGFloat, step: CGFloat, steps: Int) {
            self.fixture = fixture
            widths = (0..<steps).map { from + step * CGFloat($0) }
        }

        func run() async -> Result {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finished = done
                let window = fixture.window
                let client = FrameClient(owner: "test.terminalDragCadence", isAnimation: false,
                                         scheduler: { FrameScheduler.forWindow(window) }) { [weak self] _ in
                    self?.tick() ?? false
                }
                self.client = client
                client.activate()
            }
            client = nil
            return Result(lags: lags, states: states)
        }

        /// One refresh: what the last refresh's commits show, then the next width.
        private func tick() -> Bool {
            let view = fixture.session.surfaceView
            if let last = wanted.indices.last, last >= 8, let shown = fixture.shownPixels?.width {
                // How many refreshes ago the size the terminal shows now was asked (the whole drag when none was).
                let asked = wanted.lastIndex(of: shown) ?? -1
                lags.append(last - asked)
                if view.frameOwnership.embedderPresents {
                    states[Self.name(view.hostFrame(present: false)), default: 0] += 1
                }
            }
            guard wanted.count < widths.count else {
                finished?.resume()
                finished = nil
                return false
            }
            let width = widths[wanted.count]
            let scale = view.layer?.contentsScale ?? 2
            wanted.append(Int((width * scale).rounded()))
            fixture.container.terminalWidth = width
            fixture.container.needsLayout = true
            return true
        }

        private static func name(_ state: ghostty_host_frame_e) -> String {
            switch state {
            case GHOSTTY_HOST_FRAME_NONE: "none"
            case GHOSTTY_HOST_FRAME_HIDDEN: "hidden"
            case GHOSTTY_HOST_FRAME_SHOWN: "shown"
            case GHOSTTY_HOST_FRAME_READY: "ready"
            case GHOSTTY_HOST_FRAME_PRESENTED: "presented"
            case GHOSTTY_HOST_FRAME_PENDING: "pending"
            case GHOSTTY_HOST_FRAME_HELD: "held"
            default: "other"
            }
        }
    }
}
