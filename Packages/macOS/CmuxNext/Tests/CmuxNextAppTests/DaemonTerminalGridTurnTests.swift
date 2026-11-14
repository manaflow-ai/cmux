import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import Testing

/// T-KEYS 4: a key resize's first PTY grid landed 57 ms after the key (bench 41d16acc, cmux10s, 120 Hz), and each later
/// one 41.6 ms (5 refreshes) after the one before. The view's ``TerminalGridReporter`` already lets at most one grid per
/// window go (then 25 ms, one per refresh since RESIZE P0 6); the daemon IO then gave that grid to ``ResizeCoordinator/submit(_:size:window:)``, which sent it
/// one display frame later: a second coalescer behind the first, one refresh on every grid (the first, each one in the
/// spring and the final one). A grid the view reports on the main actor reaches the daemon in the report's turn; the
/// one-in-flight echo rule and a full screen transition's hold still apply (``ResizeCoordinatorFinalGridTests``).
@MainActor
@Suite struct DaemonTerminalGridTurnTests {
    private static func io(_ resizes: ResizeCoordinator) -> DaemonTerminalIO {
        let attachment = TerminalAttachment.Target(surface: SurfaceID(rawValue: 41), terminalResourceID: nil, generation: nil)
        return DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: resizes,
                                visible: false, endpoint: { throw CancellationError() })
    }

    @Test func aReportedGridReachesTheDaemonInTheReportsTurn() {
        let resizes = ResizeCoordinator(holds: { _ in false })
        var sent: [CellSize] = []
        resizes.onSend = { _, size in sent.append(size) }
        let io = Self.io(resizes)
        #expect(io.resizeOnMain(cols: 100, rows: 30, window: nil))
        #expect(sent == [CellSize(cols: 100, rows: 30)],
                "the grid waited for the coordinator's next frame (sent in the report's turn: \(sent)): one refresh more per grid")
        _ = resizes.tick()
        #expect(sent == [CellSize(cols: 100, rows: 30)], "the grid went \(sent.count) times")
    }

    /// A full screen transition still holds the grid until it ends (PL-burst M6, fullscreen-lag).
    @Test func aFullScreenTransitionStillHoldsTheGrid() {
        var transitioning = true
        let resizes = ResizeCoordinator(holds: { _ in transitioning })
        var sent: [CellSize] = []
        resizes.onSend = { _, size in sent.append(size) }
        let io = Self.io(resizes)
        #expect(io.resizeOnMain(cols: 100, rows: 30, window: nil))
        #expect(resizes.tick(), "the frames stop while the transition holds the grid")
        #expect(sent.isEmpty, "a grid went mid-transition: \(sent)")
        transitioning = false
        _ = resizes.tick()
        #expect(sent == [CellSize(cols: 100, rows: 30)], "the held grid went \(sent) at the transition's end")
    }
}
