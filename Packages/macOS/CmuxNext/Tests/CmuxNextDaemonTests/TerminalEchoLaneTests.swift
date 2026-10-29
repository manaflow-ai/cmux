import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The terminal echo lane: once the view names its output lane, live output goes from the attach
/// reader thread straight to it (``TerminalEchoRouter``), with no AsyncStream, task or pool thread between, in order
/// with every record still on the stream (one marker sequence), held back by the lane's capacity on the reader
/// thread, and nothing accepted is lost when the link detaches.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalEchoLaneTests {
    // MARK: Fixtures

    /// A view's lane as the reader feeds it: logs each chunk into `log` and calls `onTake` after it; `holdNext` makes
    /// the next chunk report a full lane and keeps its wake for ``drain()``.
    private final class FakeLane: Sendable {
        private struct State {
            var chunks: [Data] = []
            var arrivals: [ContinuousClock.Instant] = []
            var holdNext = false
            var wake: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())
        private let log: Log?
        private let onTake: (@Sendable () -> Void)?

        init(log: Log? = nil, onTake: (@Sendable () -> Void)? = nil) {
            self.log = log
            self.onTake = onTake
        }

        var sink: TerminalEchoSink {
            TerminalEchoSink { [self] data, _, wake in
                take(data, wake: wake)
            }
        }

        private func take(_ data: Data, wake: @escaping @Sendable () -> Void) -> Bool {
            let now = ContinuousClock.now
            log?.append(data)
            let full = state.withLock { state -> Bool in
                state.chunks.append(data)
                state.arrivals.append(now)
                guard state.holdNext else { return false }
                state.holdNext = false
                state.wake = wake
                return true
            }
            onTake?()
            return full
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
    private static func openRoute(_ queue: TerminalEventQueue, to lane: FakeLane,
                                  holdLimit: Int = 2 << 20) async throws -> TerminalEchoRouter {
        let router = TerminalEchoRouter(queue: queue, holdLimit: holdLimit)
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

    /// What the saturation test's reader, lane and pool tasks share.
    private final class Saturation: Sendable {
        let spinning = Atomic<Int>(0)
        /// Set by the lane when the echo arrives: the pool stays saturated until then (or `deadline`).
        let stop = Atomic<Bool>(false)
        let handed = Mutex<ContinuousClock.Instant?>(nil)
        /// The lane's chunks when `receive` returned, read on the reader thread while every pool thread still spun.
        let onLaneWhenReceiveReturned = Mutex<[Data]?>(nil)
        let deadline = ContinuousClock.now + .seconds(10)
    }

    // MARK: Tests

    /// No pool thread is free (every one spins until the echo is on the lane), yet the echo reaches the lane
    /// within 2 ms of the reader taking the line, before `receive` returns: the reader hands it over itself. A
    /// router that handed the chunk to a task or any other pool hop would leave the lane empty until the spinners
    /// gave up at the deadline.
    @Test func anEchoReachesTheLaneWithThePoolSaturated() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let saturation = Saturation()
        let lane = FakeLane(onTake: { saturation.stop.store(true, ordering: .releasing) })
        let router = try await Self.openRoute(queue, to: lane)
        let width = ProcessInfo.processInfo.activeProcessorCount
        let reader = Reader {
            // Waits (bounded) until every pool thread spins, then takes one echo line.
            while saturation.spinning.load(ordering: .acquiring) < width, ContinuousClock.now < saturation.deadline {}
            saturation.handed.withLock { $0 = ContinuousClock.now }
            router.receive(Self.output("e", flow: 9)) { _, _ in }
            saturation.onLaneWhenReceiveReturned.withLock { $0 = lane.chunks }
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<width {
                group.addTask {
                    saturation.spinning.add(1, ordering: .acquiringAndReleasing)
                    while !saturation.stop.load(ordering: .acquiring), ContinuousClock.now < saturation.deadline {}
                }
            }
            await reader.waitUntilReturned()
        }
        let start = try #require(saturation.handed.withLock { $0 })
        let arrival = try #require(lane.arrivals.first)
        #expect(saturation.onLaneWhenReceiveReturned.withLock { $0 } == [Data("e".utf8)],
                "the echo was not on the lane when receive returned")
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

    /// Output that never pauses, while a control record and its marker are in flight: the route opens one round
    /// trip after the record all the same, and the view applies every byte in the reader's order. The output that
    /// came meanwhile waits behind the marker and goes to the lane when the view resumes it.
    @Test func nonstopOutputOpensTheRouteOneRoundTripAfterARecord() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let log = Log()
        let lane = FakeLane(log: log)
        // A small hold limit parks the reader until the view resumed the marker, so the route opens mid-run however
        // fast the reader is.
        let router = try await Self.openRoute(queue, to: lane, holdLimit: 64)
        let opened = Mutex<Int?>(nil)
        let count = 10_000
        var expected = "c0;"
        for index in 1..<count { expected += "o\(index);" }
        let reader = Reader {
            router.receive(Self.control(0)) { _, _ in }
            for index in 1..<count {
                router.receive(Self.output("o\(index);")) { _, _ in }
                if router.routesToLane { opened.withLock { $0 = $0 ?? index } }
            }
            router.receive(DecodedAttachLine(event: .closed(.detachedByClient))) { _, _ in }
        }
        consume: while let event = await queue.next() {
            switch event {
            case .output(let data, _): log.append(data)
            case .scrollChanged(let offset, _): log.append("c\(offset);")
            case .outputResume(let marker): marker.resume()
            case .closed: break consume
            default: Issue.record("unexpected \(event)")
            }
        }
        await reader.waitUntilReturned()
        let openedAt = try #require(opened.withLock { $0 }, "the route never opened while output kept coming")
        #expect(openedAt < count - 1)
        #expect(log.joined == expected)
        #expect(!lane.chunks.isEmpty)
    }

    /// cp/fix-wrap-stale-view, case 1: the v2.2.7-opt stale view (a new terminal kept its first wrapped row while the
    /// daemon's screen went on). The view applies a record (the replay of the wrapped row) and, before it resumes the
    /// marker behind it, swaps in a fresh surface's lane (a replay into a surface with content). Output that came
    /// meanwhile is held behind that marker: once the view resumed every marker it was given, all of it, and output
    /// after it, reaches the lane the view named last, in order, and the route is open again.
    @Test func outputHeldWhenTheViewSwapsLanesBehindAMarkerReachesTheNewLane() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let log = Log()
        let first = FakeLane(log: log), fresh = FakeLane(log: log)
        let router = try await Self.openRoute(queue, to: first)
        // The reader: a record, then output while its marker is in flight.
        router.receive(Self.control(1)) { _, _ in }
        router.receive(Self.output("held-1;")) { _, _ in }
        router.receive(Self.output("held-2;")) { _, _ in }
        // The view: applies the record, swaps lanes (the replay's fresh surface), then resumes markers as they come.
        guard case .scrollChanged? = await queue.next() else { throw EchoLaneTestError.noMarker }
        log.append("c1;")
        router.setSink(fresh.sink)
        var resumed = 0
        while !router.routesToLane, resumed < 8 {
            switch await queue.next() {
            case .outputResume(let marker)?:
                marker.resume()
                resumed += 1
            case .output(let data, _)?: log.append(data)
            case let other?: Issue.record("unexpected \(String(describing: other))")
            case nil: Issue.record("the stream ended")
            }
        }
        #expect(router.routesToLane, "the route stayed shut after \(resumed) markers: live output never reaches a lane")
        router.receive(Self.output("after;")) { _, _ in }
        #expect(log.joined == "c1;held-1;held-2;after;", "applied \(log.joined)")
        #expect(fresh.chunks.last == Data("after;".utf8), "live output after the swap did not reach the new lane")
        #expect(!first.chunks.contains(Data("after;".utf8)), "live output after the swap went to the replaced lane")
    }

    /// Output held behind a marker past the hold limit stops the reader on its thread until the view resumes the
    /// marker; then the held output and everything after it reach the lane, in order, and none goes by the stream.
    @Test func heldOutputPastTheHoldLimitStopsTheReaderUntilTheMarkerPasses() async throws {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = TerminalEventQueue(recorder: nil, onReaderBlocked: { blocked.yield() })
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane, holdLimit: 4)
        let reader = Reader {
            router.receive(Self.control(1)) { _, _ in }
            for text in ["abc", "def", "g"] { router.receive(Self.output(text)) { _, _ in } }
        }
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)
        #expect(lane.chunks.isEmpty, "output went to the lane before the record ahead of it was applied")
        #expect(!reader.returned)

        #expect(await queue.next() == .scrollChanged(offset: 1, atBottom: true))
        guard case .outputResume(let marker)? = await queue.next() else { throw EchoLaneTestError.noMarker }
        marker.resume()
        await reader.waitUntilReturned()
        #expect(lane.chunks == ["abc", "def", "g"].map { Data($0.utf8) })
        #expect(router.routesToLane)
        #expect(queue.bufferedOutputBytes == 0, "held output went the stream's way")
    }

    /// A record that comes while output is held takes that output onto the stream ahead of itself.
    @Test func aRecordTakesHeldOutputOntoTheStreamAheadOfItself() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane)
        router.receive(Self.control(1)) { _, _ in }
        router.receive(Self.output("a", flow: 3)) { _, _ in }
        router.receive(Self.control(2)) { _, _ in }
        #expect(await queue.next() == .scrollChanged(offset: 1, atBottom: true))
        guard case .outputResume(let first)? = await queue.next() else { throw EchoLaneTestError.noMarker }
        #expect(await queue.next() == .output(Data("a".utf8), colors: nil))
        #expect(await queue.next() == .inputEcho(flow: 3))
        #expect(await queue.next() == .scrollChanged(offset: 2, atBottom: true))
        first.resume()
        guard case .outputResume(let second)? = await queue.next() else { throw EchoLaneTestError.noMarker }
        #expect(!router.routesToLane)
        second.resume()
        #expect(router.routesToLane)
        #expect(lane.chunks.isEmpty)
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

    /// Detaching with output held behind a marker puts that output on the stream, in order, before anything later.
    @Test func detachPutsHeldOutputOnTheStream() async throws {
        let queue = TerminalEventQueue(recorder: nil)
        let lane = FakeLane()
        let router = try await Self.openRoute(queue, to: lane)
        router.receive(Self.control(1)) { _, _ in }
        router.receive(Self.output("a")) { _, _ in }
        router.close()
        router.receive(Self.output("b")) { _, _ in }
        router.finish(.closed(.detachedByClient))
        #expect(await queue.next() == .scrollChanged(offset: 1, atBottom: true))
        guard case .outputResume? = await queue.next() else { throw EchoLaneTestError.noMarker }
        #expect(await queue.next() == .output(Data("ab".utf8), colors: nil))
        #expect(await queue.next() == .closed(.detachedByClient))
        #expect(lane.chunks.isEmpty)
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
