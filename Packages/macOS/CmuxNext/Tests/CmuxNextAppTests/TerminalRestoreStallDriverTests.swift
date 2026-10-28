import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextInputModel
import Foundation
import Testing

/// Audit P13 through the driver: a restored view whose attach hangs (the daemon restoring hundreds of
/// terminals answers an attach seconds late) said "Restoring…" with no reason and no Retry for as long as
/// the attach hung. The driver waits the machine's restore deadline (`restoreStallDelay`) and reports it;
/// the view then says why with Retry, though no attach has failed.
struct TerminalRestoreStallDriverTests {
    @Test(.timeLimit(.minutes(1)))
    func aHangingRestoreSaysWhyOnceItsDeadlinePasses() async {
        let (deadline, passDeadline) = AsyncStream<Void>.makeStream()
        let waited = DelayLog()
        let hang = Hang()
        let driver = TerminalAttachDriver<HangingLink>(
            initialSize: CellSize(cols: 80, rows: 24), restoring: true,
            opener: { _ in
                // The attach hangs until the driver closes (a daemon that has not answered).
                for await _ in hang.stream {}
                throw CancellationError()
            },
            restoreStallDelay: { delay in
                waited.append(delay)
                for await _ in deadline { return }
                throw CancellationError()
            })
        driver.start()
        var statuses: [TerminalLinkStatus] = []
        while let step = await driver.nextStep() {
            guard case .status(let status) = step else { continue }
            statuses.append(status)
            if statuses.count == 1 { passDeadline.yield() }  // the 5 s pass
            if statuses.count == 2 { break }
        }
        #expect(statuses == [.restoring, .disconnected(.restoreStalled, reconnecting: false)],
                "a hanging restore said \(statuses), not why")
        #expect(waited.all == [TerminalAttachMachine<Int>.restoreStallDelay])
        driver.close()
        hang.end()
    }
}

/// An attach that never answers: its waiter ends only when cancelled or ended.
nonisolated private final class Hang: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func end() { continuation.finish() }
}

/// The delays the driver asked for.
nonisolated private final class DelayLog: Sendable {
    private let delays = Mutex<[Duration]>([])
    func append(_ delay: Duration) { delays.withLock { $0.append(delay) } }
    var all: [Duration] { delays.withLock { $0 } }
}

/// Never opened: the opener hangs.
nonisolated private final class HangingLink: TerminalAttachLink {
    let events = AsyncStream<TerminalChannelEvent>.makeStream().stream
    func sendInput(_ data: Data) {}
    func sendClaim(reporting size: CellSize) {}
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) {}
    func sendHidden(_ hidden: Bool) {}
    func sendSnapshotRequest(reason: SnapshotRequestReason) {}
    func setOutputSink(_ sink: TerminalEchoSink?) {}
    func detachNow() {}
}
