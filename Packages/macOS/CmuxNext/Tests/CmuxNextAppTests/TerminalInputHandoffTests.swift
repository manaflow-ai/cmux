import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Testing

/// A key typed at launch while the tab's terminal view still attached was lost (launch-TTI round 2:
/// `terminal.probe_key_typed` at 2569 ms, the daemon connected at 3786 ms, the key never echoed). The
/// view queued the key until its replay, but the daemon's answer gave the tab a new generation, the
/// content cache replaced the view, and the old view's close counted its queue as dropped. The old
/// view now hands its queue to the new one, which sends it right after its own replay.
struct TerminalInputHandoffTests {
    typealias Machine = TerminalAttachMachine<Int>

    @Test func aViewReplacedBeforeItWentLiveHandsItsQueuedKeysToItsReplacement() {
        var old = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        _ = old.reduce(.start)
        _ = old.reduce(.input(Data("a".utf8)))
        _ = old.reduce(.input(Data("b".utf8)))
        let held = old.takeQueuedInput()
        _ = old.reduce(.close)
        #expect(held == [Data("a".utf8), Data("b".utf8)])
        #expect(old.droppedInputBytes == 0, "handed off, not dropped")

        var new = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        _ = new.reduce(.start)
        for data in held { _ = new.reduce(.input(data)) }
        _ = new.reduce(.input(Data("c".utf8)))
        _ = new.reduce(.opened(7, attempt: 1))
        let sent = new.reduce(.replayDelivered(7)).compactMap { effect -> Data? in
            if case .send(7, let data) = effect { return data }
            return nil
        }
        #expect(sent == [Data("a".utf8), Data("b".utf8), Data("c".utf8)], "in order, right after the replay")
    }

    @Test func aPlainCloseStillDropsTheQueue() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        _ = machine.reduce(.input(Data("x".utf8)))
        _ = machine.reduce(.close)
        #expect(machine.droppedInputBytes == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theDriverClosesAndHandsBackTheKeysTypedWhileItAttached() {
        // An attach that never answers: the keys stay queued.
        let driver = TerminalAttachDriver<SilentLink>(initialSize: CellSize(cols: 80, rows: 24), restoring: true,
                                                      opener: { _ in try await Task.sleep(for: .seconds(3600)); throw CancellationError() })
        driver.start()
        driver.input(Data("k".utf8))
        let held = driver.closeHandingOffInput()
        #expect(held == [Data("k".utf8)])
        #expect(driver.machine.isClosed)
        #expect(driver.machine.droppedInputBytes == 0)
    }
}

/// A link no test opens.
nonisolated private final class SilentLink: TerminalAttachLink {
    var events: AsyncStream<TerminalChannelEvent> { AsyncStream { $0.finish() } }
    func sendInput(_ data: Data) {}
    func sendClaim(reporting size: CellSize) {}
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) {}
    func sendHidden(_ hidden: Bool) {}
    func sendSnapshotRequest(reason: SnapshotRequestReason) {}
    func detachNow() {}
}
