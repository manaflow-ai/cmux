import CmuxFuzzSupport
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextTrace
import Foundation
import Testing

/// The app reader routes only: every handler, reply resolution and close runs on the connection's
/// ``DecodeLane`` in wire order; a heavy item never runs on the reader and never holds it; a light one runs inline
/// only while the lane is idle; the reader waits only while the lane's backlog is above its high water.
extension LineTransportTests {
    /// What one lane item saw: its post index and whether it ran on the reader thread.
    struct LaneRun: Equatable, Sendable {
        var index: Int
        var onReader: Bool
    }

    /// A dedicated poster thread, as a connection's reader: marks itself a reader, runs `body`, then reports.
    private final class LaneReader: Sendable {
        private let done: AsyncStream<Void>

        init(_ body: @escaping @Sendable () -> Void) {
            let (done, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.done = done
            let thread = Thread {
                DecodeLane.markReader()
                body()
                finished.yield()
                finished.finish()
            }
            thread.name = "LineTransportTests lane reader"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func waitUntilReturned() async {
            for await _ in done { return }
        }
    }

    private static func lane(highWater: Int = DecodeLane.defaultHighWater, lowWater: Int = DecodeLane.defaultLowWater,
                             onReaderBlocked: (@Sendable () -> Void)? = nil) -> DecodeLane {
        DecodeLane(label: "LineTransportTests.decode", qos: .utility, lightQoS: .userInitiated,
                   highWater: highWater, lowWater: lowWater, onReaderBlocked: onReaderBlocked)
    }

    /// Property: for random mixes of light and heavy items, the lane runs them in post order, a heavy item never on
    /// the reader, and the first item, posted to an idle lane, inline when it is light.
    @Test func theLaneRunsEveryMixInPostOrderAndHeavyWorkOffTheReader() async {
        for seed in UInt64(1)...40 {
            var rng = FuzzRNG(seed: seed)
            let weights: [DecodeLane.Weight] = (0..<(1 + rng.below(200))).map { _ in rng.oneIn(3) ? .heavy : .light }
            let lane = Self.lane()
            let runs = Mutex<[LaneRun]>([])
            let (finished, finish) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let reader = LaneReader {
                for (index, weight) in weights.enumerated() {
                    lane.post(weight, bytes: 16) {
                        runs.withLock { $0.append(LaneRun(index: index, onReader: DecodeLane.isReaderThread)) }
                    }
                }
                lane.post(.heavy, bytes: 0) { finish.yield() }
            }
            await reader.waitUntilReturned()
            for await _ in finished { break }

            let seen = runs.withLock { $0 }
            #expect(seen.map(\.index) == Array(weights.indices), "seed \(seed): the lane reordered its items")
            for run in seen where weights[run.index] == .heavy {
                #expect(!run.onReader, "seed \(seed): heavy item \(run.index) ran on the reader")
            }
            #expect(seen.first?.onReader == (weights[0] == .light), "seed \(seed): an idle lane hopped a light item")
            #expect(lane.queuedItems == 0)
        }
    }

    /// A heavy item that does not end yet holds neither the reader nor its order: the reader posts three light
    /// items behind it and returns; they run after it, off the reader, once it ends.
    @Test func aHeavyItemNeverHoldsTheReader() async {
        let lane = Self.lane()
        let gate = DispatchSemaphore(value: 0)
        let runs = Mutex<[LaneRun]>([])
        let (finished, finish) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let reader = LaneReader {
            lane.post(.heavy, bytes: 4 << 20) {
                gate.wait()
                runs.withLock { $0.append(LaneRun(index: 0, onReader: DecodeLane.isReaderThread)) }
            }
            for index in 1...3 {
                lane.post(.light, bytes: 8) {
                    runs.withLock { $0.append(LaneRun(index: index, onReader: DecodeLane.isReaderThread)) }
                }
            }
            lane.post(.light, bytes: 0) { finish.yield() }
        }
        await reader.waitUntilReturned()
        #expect(runs.withLock { $0.isEmpty }, "an item ran before the heavy one ended")
        #expect(lane.queuedItems == 5)

        gate.signal()
        for await _ in finished { break }
        #expect(runs.withLock { $0 } == (0...3).map { LaneRun(index: $0, onReader: false) })
    }

    /// The reader parks above the lane's high water and reads again once the backlog drains to its low water.
    @Test func theReaderWaitsOnlyWhileTheBacklogIsFull() async {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let lane = Self.lane(highWater: 10, lowWater: 4) { blocked.yield() }
        let gate = DispatchSemaphore(value: 0)
        let returned = Mutex(false)
        let reader = LaneReader {
            lane.post(.heavy, bytes: 8) { gate.wait() }
            lane.waitForRoom()
            // 16 bytes queued: above the high water, the reader parks in its wait after the line.
            lane.post(.heavy, bytes: 8) {}
            lane.waitForRoom()
            returned.withLock { $0 = true }
        }
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)
        #expect(!returned.withLock { $0 })

        gate.signal()
        await reader.waitUntilReturned()
        #expect(returned.withLock { $0 })
    }

    /// End to end: a heavy event whose handler does not end yet does not hold the reader (it routes the lines after
    /// it), and the events after it and a reply still reach their handler and waiter after it, in wire order.
    @Test func aHeavyEventKeepsTheConnectionsOrderAndFreesItsReader() async throws {
        let daemon = try FakeDaemon()
        let lines = RoutedLines()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil, hangs: lines)
        try daemon.accept()
        defer { transport.close() }
        let gate = DispatchSemaphore(value: 0)
        let handled = Mutex<[String]>([])
        transport.start(dispatch: EventDispatch { name, _ in name == "big" ? .heavy : .light },
                        onEvent: { name, _, _ in
                            if name == "big" { gate.wait() }
                            handled.withLock { $0.append(name) }
                        },
                        onClose: { _ in })

        let reply = Task {
            _ = try await transport.request(cmd: "ping", timeout: nil) { Data(#"{"id":\#($0),"cmd":"ping"}"#.utf8) }
            return handled.withLock { $0 }
        }
        let id = try daemon.readRequestID()
        daemon.write([#"{"event":"big"}"#, #"{"event":"small"}"#, #"{"id":\#(id),"ok":true,"data":{}}"#])
        await lines.waitFor(3)
        #expect(transport.routedEventCount == 2, "the reader stopped behind the heavy event")
        #expect(handled.withLock { $0.isEmpty })

        gate.signal()
        #expect(try await reply.value == ["big", "small"], "the reply resolved before the events routed before it")
    }

    /// Counts the lines the reader routed (its `daemon.line` scopes), so a test can wait for the reader without
    /// waiting on the handlers.
    final class RoutedLines: HangWatchScoping {
        private let routed: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let lanes = Mutex<[String]>([])

        init() {
            let (routed, continuation) = AsyncStream<Void>.makeStream()
            self.routed = routed
            self.continuation = continuation
        }

        func registerLane(_ name: StaticString) -> HangWatch.Registration {
            lanes.withLock { lanes in
                lanes.append(name.description)
                return HangWatch.Registration(slot: UInt32(lanes.count - 1), generation: 1)
            }
        }

        func unregister(_ registration: HangWatch.Registration) {}

        func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
            let isLine = lanes.withLock { $0[Int(registration.slot)] == "daemon.line" }
            defer { if isLine { continuation.yield() } }
            return try body()
        }

        func waitFor(_ count: Int) async {
            var seen = 0
            for await _ in routed {
                seen += 1
                if seen == count { return }
            }
        }
    }
}
