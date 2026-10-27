import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The terminal echo lane (p04-input-083): once the view names its output lane, live output goes from the attach
/// reader thread straight to it (``TerminalEchoRouter``), with no AsyncStream, task or pool thread between, in order
/// with every record still on the stream (one marker sequence), held back by the lane's capacity on the reader
/// thread, and nothing accepted is lost when the link detaches.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalEchoLaneTests {
    // MARK: Fixtures

    /// A view's lane as the reader feeds it: logs each chunk into `log`; `holdNext` makes the next chunk report a
    /// full lane and keeps its wake for ``drain()``.
    private final class FakeLane: Sendable {
        private struct State {
            var chunks: [Data] = []
            var arrivals: [ContinuousClock.Instant] = []
            var holdNext = false
            var wake: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())
        private let log: Log?

        init(log: Log? = nil) { self.log = log }

        var sink: TerminalEchoSink {
            TerminalEchoSink { [self] data, _, wake in
                take(data, wake: wake)
            }
        }

        private func take(_ data: Data, wake: @escaping @Sendable () -> Void) -> Bool {
            let now = ContinuousClock.now
            log?.append(data)
            return state.withLock { state -> Bool in
                state.chunks.append(data)
                state.arrivals.append(now)
                guard state.holdNext else { return false }
                state.holdNext = false
                state.wake = wake
                return true
            }
        }

        var chunks: [Data] { state.withLock { $0.chunks } }
        var arrivals: [ContinuousClock.Instant] { state.withLock { $0.arrivals } }
        func holdNext() { state.withLock { $0.holdNext = true } }

        /// The lane drained: the reader waiting on it goes on.
        func drain() { state.withLock { $0.wake.take() }?() }
    }

    /// Everything the view applied, from the stream and from its lanes, in the order it was applied.
    private final class Log: Sendable {
        private let entries = Mutex<[String]>([])
        func append(_ data: Data) { entries.withLock { $0.append(String(decoding: data, as: UTF8.self)) } }
        func append(_ text: String) { entries.withLock { $0.append(text) } }
        var joined: String { entries.withLock { $0.joined() } }
    }

    /// The attach connection's dedicated reader thread: runs `body`, then reports that it returned.
    private final class Reader: Sendable {
        private let returnedFlag = Mutex(false)
        private let done: AsyncStream<Void>

        init(_ body: @escaping @Sendable () -> Void) {
            let (done, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.done = done
            let thread = Thread { [self] in
                body()
                returnedFlag.withLock { $0 = true }
                finished.yield()
                finished.finish()
            }
            thread.name = "TerminalEchoLaneTests reader"
            // qos-allow: stands for the attach reader thread (LineTransport), which runs at this class
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        var returned: Bool { returnedFlag.withLock { $0 } }

        func waitUntilReturned() async {
            for await _ in done { return }
        }
    }

    private static func output(_ text: String, flow: UInt64? = nil) -> DecodedAttachLine {
        DecodedAttachLine(event: .output(Data(text.utf8), colors: nil), flow: flow)
    }

    private static func control(_ index: Int) -> DecodedAttachLine {
        DecodedAttachLine(event: .scrollChanged(offset: UInt64(index), atBottom: true))
    }

    /// A router whose route to `lane` is open: the marker behind nothing was resumed.
    private static func openRoute(_ queue: TerminalEventQueue, to lane: FakeLane) async throws -> TerminalEchoRouter {
        let router = TerminalEchoRouter(queue: queue)
        router.setSink(lane.sink)
        #expect(!router.routesToLane, "a new sink took output before its marker passed")
        guard case .outputResume(let marker)? = await queue.next() else {
            throw EchoLaneTestError.noMarker
        }
        marker.resume()
        #expect(router.routesToLane)
        return router
    }

    private enum EchoLaneTestError: Error { case noMarker }

    /// What the saturation test's reader and pool tasks share.
    private final class Saturation: Sendable {
        let spinning = Atomic<Int>(0)
        let stop = Atomic<Bool>(false)
        let handed = Mutex<ContinuousClock.Instant?>(nil)
    }

    // MARK: Tests

    /// No pool thread is free (every one spins), yet the echo reaches the lane within 2 ms of the reader taking
    /// the line: the reader hands it over itself.
    @Test func anEchoReachesTheLaneWithThePoolSaturated() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane)
        let width = ProcessInfo.processInfo.activeProcessorCount
        let saturation = Saturation()
        let reader = Reader {
            // Waits (bounded) until every pool thread spins, then takes one echo line.
            let deadline = ContinuousClock.now + .seconds(10)
            while saturation.spinning.load(ordering: .acquiring) < width, ContinuousClock.now < deadline {}
            saturation.handed.withLock { $0 = ContinuousClock.now }
            router.receive(Self.output("e", flow: 9)) { _, _ in }
            saturation.stop.store(true, ordering: .releasing)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<width {
                group.addTask {
                    saturation.spinning.add(1, ordering: .acquiringAndReleasing)
                    while !saturation.stop.load(ordering: .acquiring) {}
                }
            }
            await reader.waitUntilReturned()
        }
        let start = try #require(saturation.handed.withLock { $0 })
        let arrival = try #require(lane.arrivals.first)
        #expect(lane.chunks == [Data("e".utf8)])
        #expect(arrival - start < .milliseconds(2), "the echo waited \(arrival - start) for the lane")
        #expect(queue.bufferedOutputBytes == 0, "the echo went the stream's way")
    }

    /// 10k records, output and control interleaved, some output by the stream and some by the lane, and a lane
    /// swap partway: the view applies every one in the reader's order.
    @Test func tenThousandInterleavedRecordsStayInOrder() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let log = Log()
        let first = FakeLane(log: log), second = FakeLane(log: log)
        let router = try await Self.openRoute(queue, to: first)
        let count = 10_000
        var expected = ""
        for index in 0..<count { expected += index % 7 == 0 ? "c\(index);" : "o\(index);" }
        let reader = Reader {
            for index in 0..<count {
                if index % 7 == 0 {
                    router.receive(Self.control(index)) { _, _ in }
                    // Every other one waits (bounded) for the view to apply it, so the next output goes by the lane;
                    // between them the reader runs ahead of the view.
                    let deadline = ContinuousClock.now + .seconds(5)
                    while index % 14 == 0, !router.routesToLane, ContinuousClock.now < deadline {}
                } else {
                    router.receive(Self.output("o\(index);")) { _, _ in }
                }
            }
            router.receive(DecodedAttachLine(event: .closed(.detachedByClient))) { _, _ in }
        }
        // The view: applies stream records in order, resumes markers, and swaps lanes after a control record.
        consume: while let event = await queue.next() {
            switch event {
            case .output(let data, _): log.append(data)
            case .scrollChanged(let offset, _):
                log.append("c\(offset);")
                if offset == 5_005 { router.setSink(second.sink) }
            case .outputResume(let marker): marker.resume()
            case .closed: break consume
            default: Issue.record("unexpected \(event)")
            }
        }
        await reader.waitUntilReturned()
        #expect(log.joined == expected)
        #expect(!first.chunks.isEmpty, "no output went by the first lane")
        #expect(!second.chunks.isEmpty, "no output went by the lane swapped in")
    }

    /// A full lane stops the reader on its thread; nothing is dropped, and the lane's wake lets it read on.
    @Test func aFullLaneStopsTheReaderWithoutDrops() async throws {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = TerminalEventQueue(recorder: nil, onReaderBlocked: { blocked.yield() })
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane)
        lane.holdNext()
        let reader = Reader {
            for text in ["a", "b", "c"] { router.receive(Self.output(text)) { _, _ in } }
        }
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)
        #expect(lane.chunks == [Data("a".utf8)])
        #expect(!reader.returned)

        lane.drain()
        await reader.waitUntilReturned()
        #expect(lane.chunks == ["a", "b", "c"].map { Data($0.utf8) })
        #expect(queue.bufferedOutputBytes == 0)
    }

    /// Detaching lets a reader that waits for the lane go on; later output stays on the stream, and every byte
    /// the reader took is either on the lane or on the stream.
    @Test func detachDropsNothingAlreadyAccepted() async throws {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = TerminalEventQueue(recorder: nil, onReaderBlocked: { blocked.yield() })
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane)
        lane.holdNext()
        let reader = Reader {
            for text in ["a", "b", "c"] { router.receive(Self.output(text)) { _, _ in } }
        }
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)

        router.close()
        await reader.waitUntilReturned()
        #expect(!router.routesToLane)
        #expect(lane.chunks == [Data("a".utf8)])
        #expect(await queue.next() == .output(Data("bc".utf8), colors: nil))
        lane.drain() // the lane drains after the detach: nothing waits on it any more
    }

    /// With no lane named, output and the echo of its press stay on the stream, the echo right behind its chunk.
    @Test func withNoLaneAnEchoRidesBehindItsChunk() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let router = TerminalEchoRouter(queue: queue)
        router.receive(Self.output("a", flow: 7)) { _, _ in }
        #expect(await queue.next() == .output(Data("a".utf8), colors: nil))
        #expect(await queue.next() == .inputEcho(flow: 7))
    }
}
