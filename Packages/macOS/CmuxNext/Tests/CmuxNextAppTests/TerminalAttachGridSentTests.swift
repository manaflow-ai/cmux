import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Testing

/// `TerminalAttachDriver`'s `onGridSent` (the burst bench's `pty_grid` mark): it reports a grid only
/// when the driver really sends it to the PTY, and whether the daemon will echo it. Before, the bench
/// marked every settled resize, so a resize before the link was live, of the size the view already
/// held, or of a hidden view counted as a grid sent (and armed the next output as the TUI's redraw)
/// though nothing went out.
struct TerminalAttachGridSentTests {
    @Test(.timeLimit(.minutes(1)))
    func aGridIsReportedOnlyWhenItGoesToThePTY() async {
        let (log, logInput) = AsyncStream<String>.makeStream()
        let link = FakeLink(log: logInput)
        let grids = GridRecorder()
        let driver = TerminalAttachDriver<FakeLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link },
                                                    onGridSent: { size, expectsEcho in grids.append(size, expectsEcho) })
        var lines = log.makeAsyncIterator()

        driver.resize(CellSize(cols: 100, rows: 30))  // no live link yet: nothing goes out
        driver.start()
        link.feed.yield(.replay(TerminalReplay(cols: 80, rows: 24, data: Data())))
        let afterReplay = await lines.next()
        #expect(afterReplay == "claim 100x30", "the replay brings the view's latest grid to the PTY")

        driver.resize(CellSize(cols: 100, rows: 30))  // the grid it already holds: nothing goes out
        driver.resize(CellSize(cols: 90, rows: 30))
        let resized = await lines.next()
        #expect(resized == "claim 90x30")

        // The daemon applies 90x30 and announces it; once the view has its grid step, a take over of
        // that same grid still goes out, but the daemon will not echo it.
        link.feed.yield(.resized(TerminalReplay(cols: 90, rows: 30, data: Data())))
        while let step = await driver.nextStep() {
            if case .grid(columns: 90, rows: 30) = step { break }
        }
        driver.takeOver(setLatest: false)
        let tookOver = await lines.next()
        #expect(tookOver == "takeOver 90x30")

        driver.setVisible(false)
        let hidden = await lines.next()
        #expect(hidden == "hide")
        driver.resize(CellSize(cols: 70, rows: 30))  // hidden: nothing goes out

        driver.close()
        let closed = await lines.next()
        #expect(closed == "detach", "effects apply in order, so no claim went out after the hide")
        #expect(grids.all == [Sent(size: CellSize(cols: 100, rows: 30), expectsEcho: true),
                              Sent(size: CellSize(cols: 90, rows: 30), expectsEcho: true),
                              Sent(size: CellSize(cols: 90, rows: 30), expectsEcho: false)])
    }
}

/// One grid `onGridSent` reported.
nonisolated private struct Sent: Equatable, Sendable {
    let size: CellSize
    let expectsEcho: Bool
}

/// A link that logs what the driver sends on it; `feed` plays its stream.
nonisolated private final class FakeLink: TerminalAttachLink {
    let events: AsyncStream<TerminalChannelEvent>
    let feed: AsyncStream<TerminalChannelEvent>.Continuation
    private let log: AsyncStream<String>.Continuation

    init(log: AsyncStream<String>.Continuation) {
        let (events, feed) = AsyncStream<TerminalChannelEvent>.makeStream()
        self.events = events
        self.feed = feed
        self.log = log
    }

    func sendInput(_ data: Data) {}
    func sendClaim(reporting size: CellSize) { log.yield("claim \(size.cols)x\(size.rows)") }
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) { log.yield("takeOver \(size.cols)x\(size.rows)") }
    func sendHidden(_ hidden: Bool) { log.yield(hidden ? "hide" : "unhide") }
    func sendSnapshotRequest(reason: SnapshotRequestReason) {}
    func detachNow() {
        log.yield("detach")
        feed.finish()
    }
}

/// The grids `onGridSent` reported, in order.
nonisolated private final class GridRecorder: Sendable {
    // A lock: `onGridSent` is a synchronous callback under the driver's reducer lock (any thread).
    private let grids = Mutex<[Sent]>([])

    func append(_ size: CellSize, _ expectsEcho: Bool) { grids.withLock { $0.append(Sent(size: size, expectsEcho: expectsEcho)) } }
    var all: [Sent] { grids.withLock { $0 } }
}
