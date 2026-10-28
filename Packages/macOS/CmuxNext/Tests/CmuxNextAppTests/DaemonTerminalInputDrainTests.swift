import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// A daemon terminal's input lane drains through `DaemonTerminalIO.inputDrain(on:driver:creating:)`
/// (the drain `inputDrain()` returns): every record reaches the attach driver on the input
/// queue, in lane order. While the terminal is still being created a chunk goes by id and the lane holds every later
/// record until that send returned; a chunk the daemon refused goes by the attachment before them; once the
/// input goes by the attachment, bytes go to the link without an await.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonTerminalInputDrainTests {
    @MainActor @Test func recordsKeepLaneOrderAndNoneOvertakesAHeldChunk() async {
        let log = RouteLog()
        let link = RouteLink(log: log)
        // qos-allow: a test queue standing for the attach input queue, which runs at this class
        let queue = DispatchQueue(label: "com.cmuxterm.next.test.attach-input", qos: .userInteractive)
        let driver = TerminalAttachDriver<RouteLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link },
                                                     observer: { event, _ in log.observed(event, onQueue: queue.label) })
        defer { driver.close() }
        // The link goes live: its replay brings the view's grid to the PTY.
        driver.resize(CellSize(cols: 100, rows: 30))
        driver.start()
        link.feed.yield(.replay(TerminalReplay(cols: 80, rows: 24, data: Data())))
        await log.waitForLink("claim 100x30")

        let creating = ScriptedCreatingInput()
        let lane = TerminalInputLane(drain: DaemonTerminalIO.inputDrain(on: queue, driver: driver, creating: creating))
        lane.push(.bytes(Data("a".utf8)))  // by id, slow: the lane holds
        await creating.waitForSend(count: 1)
        lane.push(.focusGained)
        lane.push(.takeOverSize(setLatest: true))
        lane.push(.reconnect)
        lane.push(.bytes(Data("b".utf8)))  // by id, refused: by the attachment
        lane.push(.resync)
        lane.push(.bytes(Data("c".utf8)))  // by the attachment at once
        #expect(log.driverEvents.isEmpty, "a record passed the chunk still sent by id")

        creating.finishSlowSend()
        await log.waitForLink("input c")

        #expect(creating.sends == ["a", "b"])
        #expect(log.driverEvents == ["focused", "takeOver true", "reconnect", "input b", "input c"])
        #expect(log.offQueue.isEmpty, "driver calls ran off the input queue: \(log.offQueue)")
        let inputs = log.linkCalls.filter { $0.hasPrefix("input") || $0.hasPrefix("snapshot") }
        #expect(inputs == ["input b", "snapshot gap", "input c"])
    }

    /// A key's bytes reach the live link with its latency slot's flow, so the daemon stamps the
    /// key's stages; other bytes go without one.
    @MainActor @Test func aKeysBytesCarryItsFlowToTheLiveLink() async {
        let log = RouteLog()
        let link = RouteLink(log: log)
        // qos-allow: a test queue standing for the attach input queue, which runs at this class
        let queue = DispatchQueue(label: "com.cmuxterm.next.test.attach-input-flow", qos: .userInteractive)
        let driver = TerminalAttachDriver<RouteLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link })
        defer { driver.close() }
        let lane = TerminalInputLane(drain: DaemonTerminalIO.inputDrain(on: queue, driver: driver, creating: nil))
        driver.resize(CellSize(cols: 100, rows: 30))
        driver.start()
        link.feed.yield(.replay(TerminalReplay(cols: 80, rows: 24, data: Data())))
        await log.waitForLink("claim 100x30")

        lane.push(.keyBytes(Data("k".utf8), keyFlow: 7))
        lane.push(.bytes(Data("p".utf8)))
        await log.waitForLink("input p")
        let inputs = log.linkCalls.filter { $0.hasPrefix("input") || $0.hasPrefix("key") }
        #expect(inputs == ["key k flow 7", "input p"])
    }
}

/// What the driver reduced (its observer) and what it sent on the link, in order.
private nonisolated final class RouteLog: Sendable {
    private nonisolated struct State {
        var driverEvents: [String] = []
        var offQueue: [String] = []
        var linkCalls: [String] = []
        var waiter: (call: String, continuation: CheckedContinuation<Void, Never>)?
    }

    // A lock: the driver's observer and the link run on whatever thread sends.
    private let state = Mutex(State())

    var driverEvents: [String] { state.withLock { $0.driverEvents } }
    var offQueue: [String] { state.withLock { $0.offQueue } }
    var linkCalls: [String] { state.withLock { $0.linkCalls } }

    /// The driver events a lane record makes, and whether each was reduced on the queue labeled `label`.
    func observed(_ event: TerminalAttachDriver<RouteLink>.Machine.Event, onQueue label: String) {
        let name: String
        switch event {
        case .input(let data): name = "input \(String(decoding: data, as: UTF8.self))"
        case .focused: name = "focused"
        case .takeOver(let setLatest): name = "takeOver \(setLatest)"
        case .reconnect: name = "reconnect"
        default: return
        }
        let onQueue = String(cString: __dispatch_queue_get_label(nil)) == label
        state.withLock { state in
            state.driverEvents.append(name)
            if !onQueue { state.offQueue.append(name) }
        }
    }

    func link(_ call: String) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.linkCalls.append(call)
            guard let waiter = state.waiter, waiter.call == call else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    /// Returns once the link saw `call`.
    func waitForLink(_ call: String) async {
        await withCheckedContinuation { continuation in
            let seen = state.withLock { state -> Bool in
                guard !state.linkCalls.contains(call) else { return true }
                state.waiter = (call, continuation)
                return false
            }
            if seen { continuation.resume() }
        }
    }
}

/// A link that logs each command the driver sends on it; `feed` plays its stream.
private nonisolated final class RouteLink: TerminalAttachLink {
    let events: AsyncStream<TerminalChannelEvent>
    let feed: AsyncStream<TerminalChannelEvent>.Continuation
    private let log: RouteLog

    init(log: RouteLog) {
        (events, feed) = AsyncStream<TerminalChannelEvent>.makeStream()
        self.log = log
    }

    func sendInput(_ data: Data, keyFlow: UInt64) {
        let text = String(decoding: data, as: UTF8.self)
        log.link(keyFlow == 0 ? "input \(text)" : "key \(text) flow \(keyFlow)")
    }
    func sendClaim(reporting size: CellSize) { log.link("claim \(size.cols)x\(size.rows)") }
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) { log.link("takeOver \(size.cols)x\(size.rows)") }
    func sendHidden(_ hidden: Bool) { log.link(hidden ? "hide" : "unhide") }
    func sendSnapshotRequest(reason: SnapshotRequestReason) { log.link("snapshot \(reason.rawValue)") }
    func setOutputSink(_ sink: TerminalEchoSink?) {}
    func detachNow() { feed.finish() }
}

/// The by-id sends of a terminal still being created: the first waits until ``finishSlowSend()`` and is
/// sent; the second is refused, after which input goes by the attachment for good.
private nonisolated final class ScriptedCreatingInput: CreatingTerminalInputSending {
    private nonisolated struct State {
        var sends: [String] = []
        var byAttachment = false
        var slow: CheckedContinuation<Void, Never>?
        var slowFinished = false
        var sendWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    }

    // A lock: the route calls from its queue and from the send's task.
    private let state = Mutex(State())

    var sends: [String] { state.withLock { $0.sends } }
    var sendsByAttachment: Bool { state.withLock { $0.byAttachment } }

    func write(_ data: Data) async -> Bool {
        let (index, waiter) = state.withLock { state -> (Int, CheckedContinuation<Void, Never>?) in
            state.sends.append(String(decoding: data, as: UTF8.self))
            guard let waiter = state.sendWaiter, state.sends.count >= waiter.count else { return (state.sends.count, nil) }
            state.sendWaiter = nil
            return (state.sends.count, waiter.continuation)
        }
        waiter?.resume()
        guard index == 1 else {
            state.withLock { $0.byAttachment = true }
            return false
        }
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state -> Bool in
                guard !state.slowFinished else { return true }
                state.slow = continuation
                return false
            }
            if finished { continuation.resume() }
        }
        return true
    }

    /// Lets the first, slow send return.
    func finishSlowSend() {
        let slow = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.slowFinished = true
            defer { state.slow = nil }
            return state.slow
        }
        slow?.resume()
    }

    /// Returns once `count` sends started.
    func waitForSend(count: Int) async {
        await withCheckedContinuation { continuation in
            let started = state.withLock { state -> Bool in
                guard state.sends.count < count else { return true }
                state.sendWaiter = (count, continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }
}
