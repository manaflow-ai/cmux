import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// `TerminalAttachDriver.setOutputSink(_:)`: the view's output lane reaches the link it pumps,
/// a link it opens later (a reattach), and a nil sink takes it back; the stream's resume marker passes through
/// the driver's steps as `outputResume`, so the view can resume it in step order.
@Suite(.timeLimit(.minutes(1))) struct TerminalAttachDriverOutputSinkTests {
    @Test func theSinkReachesTheLiveLinkAndEveryLaterOne() async {
        let (opened, report) = AsyncStream<SinkLink>.makeStream()
        let driver = TerminalAttachDriver<SinkLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in
            let link = SinkLink()
            report.yield(link)
            return link
        })
        defer { driver.close() }
        var links = opened.makeAsyncIterator()
        let sink = TerminalEchoSink { _, _, _ in false }
        driver.start()
        guard let first = await links.next() else {
            Issue.record("no link opened")
            return
        }
        await Self.pump(first, on: driver)
        driver.setOutputSink(sink)
        #expect(first.sink === sink)

        // The view fell behind: the driver reattaches, and the new link has the same sink once it is pumped.
        first.feed.yield(.closed(.overflow))
        guard let second = await links.next() else {
            Issue.record("no reattach")
            return
        }
        await Self.pump(second, on: driver)
        #expect(second.sink === sink)

        driver.setOutputSink(nil)
        #expect(second.sink == nil)
    }

    /// Plays a replay on `link` and waits for its step: the driver pumps the link from then on.
    private static func pump(_ link: SinkLink, on driver: TerminalAttachDriver<SinkLink>) async {
        link.feed.yield(.replay(TerminalReplay(cols: 80, rows: 24, data: Data())))
        while let step = await driver.nextStep() {
            if case .replay = step { return }
        }
    }

    @Test func aResumeMarkerIsAStep() async {
        let link = SinkLink()
        let driver = TerminalAttachDriver<SinkLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link })
        defer { driver.close() }
        driver.start()
        await Self.pump(link, on: driver)
        let resumed = Resumed()
        let marker = TerminalOutputMarker(sequence: 4) { sequence in resumed.record(sequence) }
        link.feed.yield(.outputResume(marker))
        guard case .outputResume(let step)? = await driver.nextStep() else {
            Issue.record("the marker did not pass as a step")
            return
        }
        #expect(step == marker)
        step.resume()
        #expect(resumed.sequence == 4)
    }
}

/// A link that records the sink the driver gives it; `feed` plays its stream.
nonisolated private final class SinkLink: TerminalAttachLink {
    let events: AsyncStream<TerminalChannelEvent>
    let feed: AsyncStream<TerminalChannelEvent>.Continuation
    private let held = Mutex<TerminalEchoSink?>(nil)

    init() {
        (events, feed) = AsyncStream<TerminalChannelEvent>.makeStream()
    }

    var sink: TerminalEchoSink? { held.withLock { $0 } }

    func sendInput(_ data: Data, keyFlow: UInt64) {}
    func sendClaim(reporting size: CellSize) {}
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) {}
    func sendHidden(_ hidden: Bool) {}
    func sendSnapshotRequest(reason: SnapshotRequestReason) {}
    func setOutputSink(_ sink: TerminalEchoSink?) { held.withLock { $0 = sink } }
    func detachNow() { feed.finish() }
}

/// The sequence a marker was resumed with.
nonisolated private final class Resumed: Sendable {
    private let value = Mutex<UInt64?>(nil)
    func record(_ sequence: UInt64) { value.withLock { $0 = sequence } }
    var sequence: UInt64? { value.withLock { $0 } }
}
