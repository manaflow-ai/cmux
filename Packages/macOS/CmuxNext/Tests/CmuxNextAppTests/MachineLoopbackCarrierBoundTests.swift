@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextRemoteView
import Foundation
import Testing

/// The machine loopback carrier's outbox, the frames the transport sends that the stream has not
/// written for want of daemon credit, holds at most its bound: past it the path ends (`.closed`)
/// instead of buffering without limit (p07-memory-098). It was unbounded, so a host that stopped
/// granting credit grew it with every frame the transport sent.
@Suite(.serialized, .timeLimit(.minutes(3))) struct MachineLoopbackCarrierBoundTests {
    static let window = 256 << 10
    static let bound = 1 << 20

    /// 100 MB in rounds of one bound each: the daemon grants no credit while a round queues, so the
    /// outbox fills to the bound and holds; then it grants credit and the round reaches the daemon.
    /// The outbox never passes the bound, the path never ends, and every byte arrives in order.
    @Test func aStalledDaemonHoldsTheOutboxAtTheBoundAndResumesWithNoLostByte() async throws {
        let daemon = FakeLoopbackDaemon()
        let stream = daemon.open(window: Self.window)
        let carrier = MachineLoopbackCarrier(outboxBound: Self.bound) { stream }
        let events = CarrierEventLog()
        var next = events.stream.makeAsyncIterator()
        carrier.start(queue: DispatchQueue(label: "test.loopback.carrier"), events: events.record)
        #expect(await next.next() == .ready)

        let total = 100 << 20
        var sent = 0
        var mostQueued = 0
        while sent < total {
            daemon.stall()
            for _ in 0..<(Self.bound / LoopbackFrames.frameBytes) {
                carrier.send(LoopbackFrames.frame(at: sent))
                sent += LoopbackFrames.frameBytes
                mostQueued = max(mostQueued, carrier.queuedOutboxBytes)
            }
            await daemon.release(untilReceived: sent)
        }

        #expect(mostQueued <= Self.bound, "the outbox held \(mostQueued) bytes, past \(Self.bound)")
        #expect(daemon.received == total, "every byte reaches the daemon")
        #expect(daemon.mismatches == 0, "in order")
        #expect(!events.seen.contains(.closed), "the path stayed open")
        carrier.cancel()
    }

    /// A transport that keeps sending to a daemon that grants nothing ends the path at the bound,
    /// once: the outbox never holds more, and what the daemon got is the start of what was sent.
    @Test func aFloodPastTheBoundEndsThePathInsteadOfBuffering() async throws {
        let daemon = FakeLoopbackDaemon()
        let stream = daemon.open(window: Self.window)
        let carrier = MachineLoopbackCarrier(outboxBound: Self.bound) { stream }
        let events = CarrierEventLog()
        var next = events.stream.makeAsyncIterator()
        carrier.start(queue: DispatchQueue(label: "test.loopback.carrier"), events: events.record)
        #expect(await next.next() == .ready)

        daemon.stall()
        var mostQueued = 0
        var offset = 0
        while offset < 100 << 20 {
            carrier.send(LoopbackFrames.frame(at: offset))
            offset += LoopbackFrames.frameBytes
            mostQueued = max(mostQueued, carrier.queuedOutboxBytes)
        }

        #expect(await next.next() == .closed)
        #expect(mostQueued <= Self.bound, "the outbox held \(mostQueued) bytes, past \(Self.bound)")
        #expect(daemon.received <= Self.window, "the daemon got only what its window allowed")
        #expect(daemon.mismatches == 0)
        carrier.cancel()
    }
}

/// The test's frames: every byte of a frame is its index mod 251, so a frame out of place or a lost
/// one shows.
private nonisolated struct LoopbackFrames {
    static let frameBytes = 64 << 10

    /// The frame that starts at byte `offset` (a multiple of ``frameBytes``).
    static func frame(at offset: Int) -> Data {
        Data(repeating: UInt8((offset / frameBytes) % 251), count: frameBytes)
    }
}

/// The carrier's events, in order, as a stream and a log.
private nonisolated final class CarrierEventLog: Sendable {
    enum Kind: Sendable, Equatable { case ready, data, closed }

    let stream: AsyncStream<Kind>
    private let continuation: AsyncStream<Kind>.Continuation
    private let log = Mutex<[Kind]>([])

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Kind.self, bufferingPolicy: .bufferingOldest(64))
    }

    var record: @Sendable (RemoteRdCarrierEvent) -> Void {
        { [continuation, log] event in
            let kind: Kind = switch event {
            case .ready: .ready
            case .data: .data
            case .closed: .closed
            }
            log.withLock { $0.append(kind) }
            continuation.yield(kind)
        }
    }

    var seen: [Kind] { log.withLock { $0 } }
}

/// The daemon end of one `loopback-forward-v1` stream: takes each `loopback-data` line, checks its
/// bytes against ``LoopbackFrames/frame(at:)``, and grants its credit back at once or, while
/// stalled, only at ``release(untilReceived:)``.
private nonisolated final class FakeLoopbackDaemon: LoopbackLineSending {
    private struct State {
        var stream: LoopbackStream?
        var stalled = false
        var owed = 0
        var received = 0
        var mismatches = 0
        var target = 0
        var reached: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var received: Int { state.withLock(\.received) }
    var mismatches: Int { state.withLock(\.mismatches) }

    /// The stream this daemon serves, opened with `window` bytes of credit each way.
    func open(window: Int) -> LoopbackStream {
        let stream = LoopbackStream(id: 1, receiveWindow: window, sender: self, onFinish: { _ in })
        state.withLock { $0.stream = stream }
        stream.opened(address: "127.0.0.1:1", sendWindow: window)
        return stream
    }

    func stall() {
        state.withLock { $0.stalled = true }
    }

    /// Grants the credit held back and every later frame's at once; returns once `total` bytes arrived.
    func release(untilReceived total: Int) async {
        await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in
            let (stream, owed, done) = state.withLock { state -> (LoopbackStream?, Int, Bool) in
                state.stalled = false
                let owed = state.owed
                state.owed = 0
                guard state.received < total else { return (state.stream, owed, true) }
                state.target = total
                state.reached = reached
                return (state.stream, owed, false)
            }
            if owed > 0, let stream { stream.deliver(.credit(stream: stream.id, bytes: owed)) }
            if done { reached.resume() }
        }
    }

    func send(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["cmd"] as? String == "loopback-data",
              let text = object["data"] as? String, let bytes = Data(base64Encoded: text) else { return true }
        let (stream, grant, reached) = state.withLock { state -> (LoopbackStream?, Int, CheckedContinuation<Void, Never>?) in
            let start = state.received % LoopbackFrames.frameBytes
            let expected = LoopbackFrames.frame(at: state.received - start)
            if start + bytes.count > expected.count || bytes != expected[start..<(start + bytes.count)] { state.mismatches += 1 }
            state.received += bytes.count
            var reached: CheckedContinuation<Void, Never>?
            if state.reached != nil, state.received >= state.target { reached = state.reached.take() }
            guard !state.stalled else {
                state.owed += bytes.count
                return (state.stream, 0, reached)
            }
            return (state.stream, bytes.count, reached)
        }
        if grant > 0, let stream { stream.deliver(.credit(stream: stream.id, bytes: grant)) }
        reached?.resume()
        return true
    }
}
