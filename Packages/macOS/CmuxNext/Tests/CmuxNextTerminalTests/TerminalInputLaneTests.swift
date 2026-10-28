import CmuxNextCompat
import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// A session's input lane: records reach the IO's queue in the order each thread pushed
/// them, through the main thread's ring and the overflow alike; a push never waits for the drain, and the
/// main thread's wait for the overflow lock stays under 2 ms while the consumer takes a large overflow; a
/// held record keeps later ones; the local PTY drains on its own write queue (one hop from the key).
@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalInputLaneTests {
    @MainActor @Test func tenThousandInterleavedRecordsDrainInOrder() async {
        let drained = DrainRecorder()
        // A small ring: the pushes spill to the overflow and come back to the ring many times.
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 16)
        let pushed = (0..<10_000).map(Self.record)
        for record in pushed { #expect(lane.push(record)) }

        #expect(await drained.wait(for: pushed.count) == pushed)
        #expect(lane.droppedRecords == 0)
    }

    @MainActor @Test func eachThreadKeepsItsOwnOrder() async {
        let drained = DrainRecorder()
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 8)
        let count = 5_000
        // Another thread (as Ghostty's replies to queries on the output lane) pushes while main does.
        let other = DispatchQueue(label: "com.cmuxterm.next.test.input-producer", qos: .userInitiated)
        let group = DispatchGroup()
        group.enter()
        other.async {
            for index in 0..<count { lane.push(.bytes(Data("o\(index)".utf8))) }
            group.leave()
        }
        for index in 0..<count { lane.push(.bytes(Data("m\(index)".utf8))) }
        await withCheckedContinuation { continuation in group.notify(queue: other) { continuation.resume() } }

        let all = await drained.wait(for: 2 * count).map { record -> String in
            guard case .bytes(let data) = record else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(all.filter { $0.hasPrefix("m") } == (0..<count).map { "m\($0)" })
        #expect(all.filter { $0.hasPrefix("o") } == (0..<count).map { "o\($0)" })
    }

    @MainActor @Test func pushesNeverWaitForABlockedDrain() async {
        let drained = DrainRecorder()
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 32)
        // The drain's queue runs nothing until resumed: a push that waited for it would never return.
        drained.queue.suspend()
        let pushed = (0..<10_000).map(Self.record)
        for record in pushed { #expect(lane.push(record)) }
        drained.queue.resume()

        #expect(await drained.wait(for: pushed.count) == pushed)
    }

    @MainActor @Test func aHeldRecordKeepsLaterOnesUntilResumed() async {
        let drained = DrainRecorder(holdFirst: true)
        let lane = TerminalInputLane(drain: drained.drain())
        let pushed = (0..<100).map(Self.record)
        for record in pushed { lane.push(record) }

        let resume = await drained.heldResume()
        #expect(drained.records.count == 1, "a record passed the held one")
        resume()
        #expect(await drained.wait(for: pushed.count) == pushed)
    }

    @MainActor @Test func overflowPastItsLimitDropsBytesAndKeepsTheRest() async {
        let drained = DrainRecorder()
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 1, overflowByteLimit: 10)
        drained.queue.suspend()
        let eight = Data(repeating: 0x61, count: 8)
        #expect(lane.push(.bytes(eight)))  // the ring
        #expect(lane.push(.bytes(eight)))  // the overflow: 8 bytes
        #expect(!lane.push(.bytes(eight))) // 16 bytes would pass the limit
        #expect(lane.push(.focusGained))   // not bytes: kept
        drained.queue.resume()

        #expect(await drained.wait(for: 3) == [.bytes(eight), .bytes(eight), .focusGained])
        #expect(lane.droppedRecords == 1)
    }

    @MainActor @Test func overflowPastItsRecordLimitDropsAnyRecord() async {
        let drained = DrainRecorder()
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 1, overflowRecordLimit: 2)
        drained.queue.suspend()
        #expect(lane.push(.reconnect))    // the ring
        #expect(lane.push(.focusGained))  // the overflow: 1 record
        #expect(lane.push(.resync))       // 2 records
        #expect(!lane.push(.focusGained)) // a third would pass the limit
        drained.queue.resume()

        #expect(await drained.wait(for: 3) == [.reconnect, .focusGained, .resync])
        #expect(lane.droppedRecords == 1)
    }

    /// Acceptance of p04-input-058: the main thread's push never waits long for the overflow lock. The
    /// consumer takes a 500 000-record overflow (it held the lock for the whole move before, O(records))
    /// while another thread keeps pushing; every main-thread push stays under 2 ms.
    @MainActor @Test func mainPushesStayUnderTwoMillisecondsWhileTheConsumerTakesALargeOverflow() async {
        let drained = DrainRecorder()
        let backlog = 500_000
        let lane = TerminalInputLane(drain: drained.drain(), ringCapacity: 16, overflowRecordLimit: 1 << 21)
        let key = Data("k".utf8)
        drained.queue.suspend()
        let other = DispatchQueue(label: "com.cmuxterm.next.test.input-producer", qos: .userInitiated)
        await withCheckedContinuation { continuation in
            other.async {
                for _ in 0..<backlog { lane.push(.bytes(key)) }
                continuation.resume()
            }
        }

        // The consumer starts on the large overflow; the other thread pushes while main does.
        let racing = 20_000, mainPushes = 5_000
        let group = DispatchGroup()
        group.enter()
        other.async {
            for _ in 0..<racing { lane.push(.bytes(key)) }
            group.leave()
        }
        drained.queue.resume()
        let clock = ContinuousClock()
        var waits: [Duration] = []
        waits.reserveCapacity(mainPushes)
        for _ in 0..<mainPushes {
            let start = clock.now
            lane.push(.focusGained)
            waits.append(clock.now - start)
        }
        await withCheckedContinuation { continuation in group.notify(queue: other) { continuation.resume() } }

        let total = backlog + racing + mainPushes
        let records = await drained.wait(for: total)
        #expect(records.count == total)
        #expect(lane.droppedRecords == 0)
        let sorted = waits.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100], worst = sorted[sorted.count - 1]
        print("TerminalInputLane main push wait: p50 \(p50) p95 \(p95) max \(worst) (\(mainPushes) pushes)")
        #expect(worst < .milliseconds(2), "a main-thread push waited \(worst) (p50 \(p50), p95 \(p95))")
    }

    @MainActor @Test func aClosedLaneDropsLaterPushes() async {
        let drained = DrainRecorder()
        let lane = TerminalInputLane(drain: drained.drain())
        #expect(lane.push(.reconnect))
        lane.close()
        #expect(!lane.push(.resync))
        #expect(await drained.wait(for: 1) == [.reconnect])
    }

    @MainActor @Test func theDefaultDrainKeepsTheAsyncCallsInOrder() async {
        let io = RecordingTerminalIO()
        let lane = TerminalInputLane(drain: .awaiting(io), ringCapacity: 16)
        let pushed = (0..<1_000).map { index -> TerminalInputRecord in
            index % 5 == 0 ? .resize(TerminalGridSize(columns: 80 + index, rows: 24), pixelWidth: 0, pixelHeight: 0)
                           : .bytes(Data("\(index)".utf8))
        }
        for record in pushed { lane.push(record) }

        #expect(await io.calls.wait(for: pushed.count) == pushed)
    }

    @Test func theLocalPTYDrainsOnItsWriteQueue() throws {
        let io = try LocalPTYTerminalIO(shell: "/bin/sh", workingDirectory: "/", environment: ["PS1": ""], installedTerminfo: false)
        defer { io.terminate() }

        let drain = io.inputDrain()
        #expect(drain.queue.label == "com.cmuxterm.next.localpty.write")
        #expect(drain.queue.qos == .userInteractive)
    }

    /// Record `index` of a mix of every kind.
    nonisolated static func record(_ index: Int) -> TerminalInputRecord {
        switch index % 7 {
        case 0: .resize(TerminalGridSize(columns: 10 + index % 300, rows: 5 + index % 90), pixelWidth: index, pixelHeight: index)
        case 1: .focusGained
        case 2: .takeOverSize(setLatest: index % 2 == 0)
        case 3: .reconnect
        case 4: .resync
        default: .bytes(Data("key \(index)".utf8))
        }
    }
}

/// Records what reaches it and wakes a waiter once enough arrived. As a drain (``drain()``) it runs on its
/// own queue; with `holdFirst` it holds the first record and hands its resume to ``heldResume()``.
private nonisolated final class DrainRecorder: Sendable {
    // qos-allow: a test drain standing for the attach input queue, which runs at this class
    let queue = DispatchQueue(label: "com.cmuxterm.next.test.input-drain", qos: .userInteractive)
    private let holdFirst: Bool
    private let state = Mutex(State())

    private nonisolated struct State {
        var records: [TerminalInputRecord] = []
        var waiter: (count: Int, continuation: CheckedContinuation<[TerminalInputRecord], Never>)?
        var held: TerminalInputResume?
        var heldWaiter: CheckedContinuation<TerminalInputResume, Never>?
    }

    init(holdFirst: Bool = false) {
        self.holdFirst = holdFirst
    }

    var records: [TerminalInputRecord] { state.withLock { $0.records } }

    func drain() -> TerminalInputDrain {
        TerminalInputDrain(queue: queue) { [self] record, resume in
            note(record, resume: resume) ? .hold : .next
        }
    }

    /// Records `record`; true when the recorder holds it (the first one, with `holdFirst`).
    @discardableResult
    func note(_ record: TerminalInputRecord, resume: TerminalInputResume? = nil) -> Bool {
        let holds = holdFirst
        let (ready, heldWaiter, hold) = state.withLock { state in
            state.records.append(record)
            let hold = holds && resume != nil && state.records.count == 1
            var heldWaiter: CheckedContinuation<TerminalInputResume, Never>?
            if hold {
                state.held = resume
                heldWaiter = state.heldWaiter
                state.heldWaiter = nil
            }
            var ready: (CheckedContinuation<[TerminalInputRecord], Never>, [TerminalInputRecord])?
            if let waiter = state.waiter, state.records.count >= waiter.count {
                state.waiter = nil
                ready = (waiter.continuation, state.records)
            }
            return (ready, heldWaiter, hold)
        }
        if let heldWaiter, let resume { heldWaiter.resume(returning: resume) }
        if let ready { ready.0.resume(returning: ready.1) }
        return hold
    }

    /// The records once `count` arrived.
    func wait(for count: Int) async -> [TerminalInputRecord] {
        await withCheckedContinuation { continuation in
            let records = state.withLock { state -> [TerminalInputRecord]? in
                guard state.records.count < count else { return state.records }
                state.waiter = (count, continuation)
                return nil
            }
            if let records { continuation.resume(returning: records) }
        }
    }

    /// The resume of the held first record, once it was drained.
    func heldResume() async -> TerminalInputResume {
        await withCheckedContinuation { continuation in
            let held = state.withLock { state -> TerminalInputResume? in
                if let held = state.held { return held }
                state.heldWaiter = continuation
                return nil
            }
            if let held { continuation.resume(returning: held) }
        }
    }
}

/// A ``TerminalIO`` with no input drain of its own: the lane's default drain awaits its calls.
private nonisolated final class RecordingTerminalIO: TerminalIO {
    let events = AsyncStream<TerminalIOEvent> { $0.finish() }
    let calls = DrainRecorder()

    func write(_ data: Data) async {
        await Task.yield() // a call that suspends: the next one must still wait for it
        calls.note(.bytes(data))
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        calls.note(.resize(TerminalGridSize(columns: cols, rows: rows), pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }
}
