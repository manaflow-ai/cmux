import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Closing a pane must not wait on its output lane. The lane can be inside Ghostty's parse of a
/// flood of titles or bells, blocked on the app mailbox (64 slots, pushed with `.forever` by
/// `surfaceMessageWriter` in ghostty src/termio/stream_handler.zig) that only the main thread's
/// `ghostty_app_tick` empties. A close that waits on the main thread for that lane never returns:
/// the main thread waits for the lane and the lane waits for the main thread.
@MainActor @Suite(.serialized) struct TerminalPaneCloseLaneTests {
    @Test func closingAPaneReturnsWhileItsLaneWaitsForTheMainThread() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init and creates the app the surface needs
        let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        defer { continuation.finish() }
        weak var closedView: TerminalSurfaceView?
        weak var bridge: SurfaceBridge?
        var view: TerminalSurfaceView? = autoreleasepool {
            TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL, input: TerminalInputSink(continuation: continuation),
                                session: nil)
        }
        let lane = try #require(view?.lane, "libghostty created no surface")
        closedView = view
        bridge = view?.bridge.takeUnretainedValue()
        let probe = LaneProbe()

        // The chunk in flight waits for the main thread, as a parse blocked on a full app
        // mailbox waits for the next tick.
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            lane.perform { _ in
                started.resume()
                probe.waitForMainTick()
            }
        }
        // The rest of the flood, queued behind it: titles and bells of a pane that has no view.
        for _ in 0..<256 {
            lane.perform { _ in probe.queuedEventRan() }
        }

        view = nil // the pane closes: the view's deinit hands the surface's teardown on
        try #require(closedView == nil, "the view outlived its last reference, so its close did not run here")
        #expect(!probe.inFlightEnded, "closing the pane waited on the main thread for the lane, which waits for the main thread")

        probe.mainTicks()
        await lane.drained()
        #expect(!probe.timedOut, "the lane's chunk got no main-thread tick before the test's deadline")
        #expect(probe.queuedEvents == 0, "title and bell events of the closed pane ran after its close")
        #expect(bridge == nil, "the surface was not freed (its bridge is still retained) after the lane finished")
    }
}

/// Stands in for Ghostty's app mailbox: the lane's chunk waits until the main thread ticks. Not
/// main-actor isolated: the lane calls it on its own queue, as it calls Ghostty's parse.
private nonisolated final class LaneProbe: Sendable {
    private struct State {
        var inFlightEnded = false
        var timedOut = false
        var queuedEvents = 0
    }

    private let tick = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    var inFlightEnded: Bool { state.withLock { $0.inFlightEnded } }
    var timedOut: Bool { state.withLock { $0.timedOut } }
    var queuedEvents: Int { state.withLock { $0.queuedEvents } }

    /// Runs on the lane. The deadline exists only in this test: it ends a close that waits on the
    /// main thread for the lane, so the test fails instead of hanging.
    func waitForMainTick() {
        let ticked = tick.wait(timeout: .now() + .seconds(20)) == .success
        state.withLock {
            $0.inFlightEnded = true
            $0.timedOut = !ticked
        }
    }

    func mainTicks() { tick.signal() }

    func queuedEventRan() { state.withLock { $0.queuedEvents += 1 } }
}
