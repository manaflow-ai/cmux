import Foundation
import Testing
@testable import CmuxIrxTransport

// MARK: - Fakes

/// In-memory server->client lane read half. Chunks are pushed by the test;
/// `readRaw` waits for the next one, like a QUIC stream with no data yet.
private actor FakeEventLaneReader: IrxEventLaneReading {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var ended = false
    private(set) var stopCodes: [UInt64] = []

    func push(_ chunk: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
        }
    }

    func end() {
        ended = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func readRaw() async throws -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if ended { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func stop(errorCode: UInt64) {
        stopCodes.append(errorCode)
        end()
    }
}

/// Feeds accepted lanes to a hub in the order the test opens them.
private final class FakeLaneAcceptor: @unchecked Sendable {
    private let stream: AsyncStream<(IrxLaneDescriptor, any IrxEventLaneReading)>
    private let continuation: AsyncStream<(IrxLaneDescriptor, any IrxEventLaneReading)>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func open(_ descriptor: IrxLaneDescriptor) -> FakeEventLaneReader {
        let reader = FakeEventLaneReader()
        continuation.yield((descriptor, reader))
        return reader
    }

    func closeConnection() { continuation.finish() }

    var accept: IrxServerEventLaneHub.AcceptLane {
        let stream = stream
        return {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
    }
}

/// In-memory lane write half. A blocked lane accepts no bytes until the test
/// releases it, like a QUIC stream out of flow credit. Like iroh-ffi, every
/// other call on the stream (priority, finish, reset) waits for an in-flight
/// write to finish, because the native stream sits behind one lock.
private actor FakeEventLaneWriter: IrxEventLaneWriting {
    let descriptor: IrxLaneDescriptor
    private let blocked: Bool
    private var blockedWrite: CheckedContinuation<Void, any Error>?
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var written: [Data] = []
    private(set) var priorities: [Int32] = []
    private(set) var finished = false
    private(set) var resetCodes: [UInt64] = []

    init(descriptor: IrxLaneDescriptor, blocked: Bool) {
        self.descriptor = descriptor
        self.blocked = blocked
    }

    func write(_ data: Data) async throws {
        await waitForStreamLock()
        guard !finished, resetCodes.isEmpty else { throw IrxFrameCodecError.unexpectedEOF }
        if blocked {
            defer { releaseStreamLock() }
            try await withCheckedThrowingContinuation { blockedWrite = $0 }
        }
        written.append(data)
    }

    func setPriority(_ priority: Int32) async {
        await waitForStreamLock()
        priorities.append(priority)
    }

    func finish() async {
        await waitForStreamLock()
        finished = true
    }

    func reset(errorCode: UInt64) async {
        await waitForStreamLock()
        resetCodes.append(errorCode)
    }

    var isWriteBlocked: Bool { blockedWrite != nil }

    /// Fails the stuck write (the connection closing), releasing the lock.
    func failBlockedWrite() {
        blockedWrite?.resume(throwing: IrxFrameCodecError.unexpectedEOF)
        blockedWrite = nil
    }

    private func waitForStreamLock() async {
        guard blockedWrite != nil else { return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func releaseStreamLock() {
        let waiters = lockWaiters
        lockWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor FakeLaneOpener {
    private(set) var opened: [FakeEventLaneWriter] = []
    var blockedSurfaces: Set<String> = []

    func block(_ surfaceID: String) { blockedSurfaces.insert(surfaceID) }
    func unblock(_ surfaceID: String) { blockedSurfaces.remove(surfaceID) }

    func open(_ descriptor: IrxLaneDescriptor) -> any IrxEventLaneWriting {
        let surfaceID = IrxSurfaceEventLaneProtocol.surfaceID(of: descriptor) ?? ""
        let writer = FakeEventLaneWriter(
            descriptor: descriptor,
            blocked: blockedSurfaces.contains(surfaceID)
        )
        opened.append(writer)
        return writer
    }

    func writers(surfaceID: String) -> [FakeEventLaneWriter] {
        opened.filter {
            IrxSurfaceEventLaneProtocol.surfaceID(of: $0.descriptor) == surfaceID
        }
    }
}

private func frame(_ text: String) -> Data {
    var length = UInt32(text.utf8.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(Data(text.utf8))
    return data
}

private func decodeFrames(_ data: Data) -> [String] {
    var buffer = data
    var result: [String] = []
    while buffer.count >= 4 {
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard buffer.count >= 4 + length else { break }
        result.append(String(decoding: buffer.dropFirst(4).prefix(length), as: UTF8.self))
        buffer.removeFirst(4 + length)
    }
    return result
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws -> Bool {
    let reached = try await withIrxDeadline(.seconds(2), onTimeout: {}) {
        while !Task.isCancelled {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    return reached == true
}

private actor FrameCollector {
    private(set) var frames: [String] = []
    func append(_ data: Data) { frames.append(contentsOf: decodeFrames(data)) }
}

private func collect(_ stream: IrxServerEventLaneHub.Output, into collector: FrameCollector) -> Task<Void, Never> {
    Task {
        do {
            for try await chunk in stream { await collector.append(chunk) }
        } catch {}
    }
}

// MARK: - Client hub

@Suite(.timeLimit(.minutes(1)))
struct IrxServerEventLaneHubTests {
    @Test func surfaceFrameIsDeliveredWhileAnotherLaneIsStalledMidFrame() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }

        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        let busy = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "A"))
        let typed = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "B"))

        // Surface A's large replay has only partly arrived; its lane is
        // waiting for the rest. Surface B's echo must not wait behind it.
        let replay = frame(String(repeating: "a", count: 64 * 1024))
        await busy.push(replay.prefix(10_000))
        await shared.push(frame("workspace.updated"))
        await typed.push(frame("echo-b"))

        #expect(try await waitUntil { await collector.frames.contains("echo-b") })
        #expect(await collector.frames.sorted() == ["echo-b", "workspace.updated"])

        await busy.push(replay.dropFirst(10_000))
        #expect(try await waitUntil { await collector.frames.count == 3 })
        await hub.stop()
    }

    @Test func framesSplitAcrossChunksArriveWholeAndInLaneOrder() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }

        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        let surface = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "S"))
        var surfaceBytes = Data()
        for index in 0..<20 { surfaceBytes.append(frame("s\(index)")) }
        var sharedBytes = Data()
        for index in 0..<20 { sharedBytes.append(frame("e\(index)")) }
        // Interleave odd-sized chunks from both lanes.
        var surfaceOffset = 0
        var sharedOffset = 0
        while surfaceOffset < surfaceBytes.count || sharedOffset < sharedBytes.count {
            if surfaceOffset < surfaceBytes.count {
                let end = min(surfaceBytes.count, surfaceOffset + 7)
                await surface.push(surfaceBytes.subdata(in: surfaceOffset..<end))
                surfaceOffset = end
            }
            if sharedOffset < sharedBytes.count {
                let end = min(sharedBytes.count, sharedOffset + 5)
                await shared.push(sharedBytes.subdata(in: sharedOffset..<end))
                sharedOffset = end
            }
        }
        #expect(try await waitUntil { await collector.frames.count == 40 })
        let frames = await collector.frames
        #expect(frames.filter { $0.hasPrefix("s") } == (0..<20).map { "s\($0)" })
        #expect(frames.filter { $0.hasPrefix("e") } == (0..<20).map { "e\($0)" })
        await hub.stop()
    }

    @Test func surfaceLanesBeyondTheLimitAreRefused() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(
            limits: .init(maximumSurfaceLaneCount: 2),
            acceptLane: acceptor.accept
        )
        _ = await hub.subscribe()
        _ = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "1"))
        _ = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "2"))
        let third = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "3"))
        #expect(try await waitUntil { await third.stopCodes == [IrxServerEventLaneHub.StopCode.laneLimit] })
        #expect(await hub.activeSurfaceLaneCount() == 2)
        await hub.stop()
    }

    @Test func endedSurfaceLaneFreesItsSlotAndKeepsTheHubAlive() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }
        let first = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "S"))
        #expect(try await waitUntil { await hub.activeSurfaceLaneCount() == 1 })
        await first.push(frame("partial").prefix(6))
        await first.end()
        #expect(try await waitUntil { await hub.activeSurfaceLaneCount() == 0 })
        // The host reopens the surface on a fresh stream after a failure.
        let reopened = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "S"))
        await reopened.push(frame("full"))
        #expect(try await waitUntil { await collector.frames == ["full"] })
        #expect(await hub.isAlive)
        await hub.stop()
    }

    @Test func replacingTheSubscriberRoutesLaterFramesToTheNewOne() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let firstCollector = FrameCollector()
        let first = collect(await hub.subscribe(), into: firstCollector)
        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        await shared.push(frame("one"))
        #expect(try await waitUntil { await firstCollector.frames == ["one"] })

        let secondCollector = FrameCollector()
        let second = collect(await hub.subscribe(), into: secondCollector)
        defer { second.cancel() }
        await first.value
        await shared.push(frame("two"))
        #expect(try await waitUntil { await secondCollector.frames == ["two"] })
        #expect(await firstCollector.frames == ["one"])
        await hub.stop()
    }

    @Test func connectionClosureFinishesTheSubscriber() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let stream = await hub.subscribe()
        acceptor.closeConnection()
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: (any Error).self) { _ = try await iterator.next() }
        #expect(await !hub.isAlive)
    }

    @Test func oversizedFrameStopsOnlyThatLane() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(
            limits: .init(maximumFrameByteCount: 16),
            acceptLane: acceptor.accept
        )
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }
        let bad = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "bad"))
        let good = acceptor.open(IrxSurfaceEventLaneProtocol.descriptor(surfaceID: "good"))
        await bad.push(frame(String(repeating: "x", count: 64)))
        await good.push(frame("ok"))
        #expect(try await waitUntil { await bad.stopCodes == [IrxServerEventLaneHub.StopCode.malformedFrame] })
        #expect(try await waitUntil { await collector.frames == ["ok"] })
        await hub.stop()
    }
}

// MARK: - Host lanes

@Suite(.timeLimit(.minutes(1)))
struct IrxSurfaceEventLanesTests {
    private func makeLanes(
        _ opener: FakeLaneOpener,
        configuration: IrxSurfaceEventLanes.Configuration = .init()
    ) -> IrxSurfaceEventLanes {
        IrxSurfaceEventLanes(configuration: configuration) { descriptor in
            await opener.open(descriptor)
        }
    }

    @Test func stalledSurfaceDoesNotDelayAnotherSurfacesWrite() async throws {
        let opener = FakeLaneOpener()
        await opener.block("a")
        let lanes = makeLanes(opener)
        let stalled = Task { try await lanes.send(frame("replay-a"), surfaceID: "A", generation: 0) }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "a").first else { return false }
            return await writer.isWriteBlocked
        })
        try await lanes.send(frame("echo-b"), surfaceID: "B", generation: 0)
        let bWriter = try #require(await opener.writers(surfaceID: "b").first)
        #expect(await bWriter.written == [frame("echo-b")])
        await lanes.closeAll()
        await opener.writers(surfaceID: "a").first?.failBlockedWrite()
        _ = await stalled.result
    }

    @Test func stalledWriteResetsTheStreamAndTheNextSendReopens() async throws {
        let opener = FakeLaneOpener()
        await opener.block("a")
        let lanes = makeLanes(opener, configuration: .init(stallDeadline: .milliseconds(50)))
        await #expect(throws: IrxSurfaceEventLanes.LaneError.writeStalled) {
            try await lanes.send(frame("x"), surfaceID: "a", generation: 0)
        }
        let stalledWriter = try #require(await opener.writers(surfaceID: "a").first)
        #expect(await lanes.openSurfaceIDs().isEmpty)

        // The stuck stream's reset waits behind its write, so recovery must
        // not: the next frame goes out on a fresh stream right away.
        await opener.unblock("a")
        try await lanes.send(frame("full"), surfaceID: "a", generation: 1)
        let writers = await opener.writers(surfaceID: "a")
        #expect(writers.count == 2)
        #expect(await writers[1].written == [frame("full")])
        #expect(await stalledWriter.resetCodes.isEmpty)

        // Once the stuck write fails, the queued reset lands on the old stream.
        await stalledWriter.failBlockedWrite()
        #expect(try await waitUntil {
            await stalledWriter.resetCodes == [IrxSurfaceEventLanes.ResetCode.stalled]
        })
    }

    @Test func newGenerationFinishesTheOldStreamAndOpensAFreshOne() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener)
        try await lanes.send(frame("1"), surfaceID: "s", generation: 0)
        try await lanes.send(frame("2"), surfaceID: "s", generation: 0)
        try await lanes.send(frame("3"), surfaceID: "s", generation: 1)
        let writers = await opener.writers(surfaceID: "s")
        #expect(writers.count == 2)
        #expect(await writers[0].written == [frame("1"), frame("2")])
        #expect(try await waitUntil { await writers[0].finished })
        #expect(await writers[1].written == [frame("3")])
    }

    @Test func focusedSurfaceIsScheduledAboveEveryOtherLane() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener)
        await lanes.noteFocused(surfaceID: "A")
        try await lanes.send(frame("a"), surfaceID: "a", generation: 0)
        try await lanes.send(frame("b"), surfaceID: "b", generation: 0)
        #expect(await lanes.priority(surfaceID: "a") == 100)
        #expect(await lanes.priority(surfaceID: "b") == 50)

        await lanes.noteFocused(surfaceID: "b")
        #expect(await lanes.priority(surfaceID: "a") == 50)
        #expect(await lanes.priority(surfaceID: "b") == 100)
        let bWriter = try #require(await opener.writers(surfaceID: "b").first)
        #expect(try await waitUntil { await bWriter.priorities == [50, 100] })
    }

    @Test func notingFocusNeverWaitsForAStalledWrite() async throws {
        let opener = FakeLaneOpener()
        await opener.block("a")
        let lanes = makeLanes(opener)
        let stalled = Task { try await lanes.send(frame("replay-a"), surfaceID: "a", generation: 0) }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "a").first else { return false }
            return await writer.isWriteBlocked
        })
        // Input on surface A marks it focused; that must return at once even
        // though A's lane is mid-write.
        await lanes.noteFocused(surfaceID: "a")
        #expect(await lanes.priority(surfaceID: "a") == 100)
        let aWriter = try #require(await opener.writers(surfaceID: "a").first)
        #expect(await aWriter.priorities == [50])
        await aWriter.failBlockedWrite()
        #expect(try await waitUntil { await aWriter.priorities == [50, 100] })
        _ = await stalled.result
        await lanes.closeAll()
    }

    @Test func laneCountIsBoundedByEvictingTheLeastRecentlyUsedLane() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 2))
        try await lanes.send(frame("1"), surfaceID: "one", generation: 0)
        try await lanes.send(frame("2"), surfaceID: "two", generation: 0)
        try await lanes.send(frame("1b"), surfaceID: "one", generation: 0)
        try await lanes.send(frame("3"), surfaceID: "three", generation: 0)
        #expect(await lanes.openSurfaceIDs() == ["one", "three"])
        let evicted = try #require(await opener.writers(surfaceID: "two").first)
        #expect(try await waitUntil { await evicted.finished })
    }

    @Test func disabledLanesRefuseToOpen() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener)
        try await lanes.send(frame("1"), surfaceID: "s", generation: 0)
        await lanes.setEnabled(false)
        await #expect(throws: IrxSurfaceEventLanes.LaneError.disabled) {
            try await lanes.send(frame("2"), surfaceID: "s", generation: 0)
        }
        #expect(await lanes.openSurfaceIDs().isEmpty)
        let writer = try #require(await opener.writers(surfaceID: "s").first)
        #expect(try await waitUntil { await writer.finished })
    }

    @Test func surfaceLaneDescriptorRoundTripsAndSharedLaneHasNoSurface() {
        let descriptor = IrxSurfaceEventLaneProtocol.descriptor(surfaceID: " ABC-def ")
        #expect(descriptor.lane == .events)
        #expect(IrxSurfaceEventLaneProtocol.surfaceID(of: descriptor) == "abc-def")
        #expect(IrxSurfaceEventLaneProtocol.surfaceID(of: IrxLaneDescriptor(lane: .events)) == nil)
        #expect(IrxSurfaceEventLaneProtocol.surfaceID(
            of: IrxLaneDescriptor(lane: .terminal, resource: "terminal:x")
        ) == nil)
    }

    @Test func frameAlignerReturnsOnlyCompleteFrames() throws {
        var aligner = IrxEventFrameAligner(maximumFrameByteCount: 1024)
        let bytes = frame("hello") + frame("world")
        #expect(try aligner.append(bytes.prefix(3)) == nil)
        let first = try #require(try aligner.append(bytes.subdata(in: 3..<12)))
        #expect(decodeFrames(first) == ["hello"])
        #expect(aligner.hasPartialFrame)
        let second = try #require(try aligner.append(bytes.dropFirst(12)))
        #expect(decodeFrames(second) == ["world"])
        #expect(!aligner.hasPartialFrame)

        var small = IrxEventFrameAligner(maximumFrameByteCount: 2)
        #expect(throws: IrxEventFrameAligner.Failure.frameTooLarge(5)) {
            _ = try small.append(frame("hello"))
        }
    }
}
