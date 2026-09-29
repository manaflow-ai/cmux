import CMUXMobileCore
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


// MARK: - Helpers

private func hubFrame(_ text: String) -> Data {
    var length = UInt32(text.utf8.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(Data(text.utf8))
    return data
}

private func hubWaitUntil(
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
    /// Each forwarded frame with the marker scope stamped before it.
    private(set) var scopedFrames: [(scope: UUID?, frame: String)] = []
    private var pendingScope: UUID?

    func append(_ data: Data) {
        var buffer = data
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            if let scope = MobileEventLaneScope().markerScope(inPayload: payload) {
                pendingScope = scope
                continue
            }
            let text = String(decoding: payload, as: UTF8.self)
            frames.append(text)
            scopedFrames.append((pendingScope, text))
            pendingScope = nil
        }
    }
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
        let busy = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "A"))
        let typed = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "B"))

        // Surface A's large replay has only partly arrived; its lane is
        // waiting for the rest. Surface B's echo must not wait behind it.
        let replay = hubFrame(String(repeating: "a", count: 64 * 1024))
        await busy.push(replay.prefix(10_000))
        await shared.push(hubFrame("workspace.updated"))
        await typed.push(hubFrame("echo-b"))

        #expect(try await hubWaitUntil { await collector.frames.contains("echo-b") })
        #expect(await collector.frames.sorted() == ["echo-b", "workspace.updated"])

        await busy.push(replay.dropFirst(10_000))
        #expect(try await hubWaitUntil { await collector.frames.count == 3 })
        await hub.stop()
    }

    @Test func everySurfaceLaneFrameArrivesBehindItsOwnTerminalsMarker() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }

        let surfaceA = UUID()
        let surfaceB = UUID()
        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        let laneA = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: surfaceA.uuidString))
        let laneB = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: surfaceB.uuidString))
        await laneA.push(hubFrame("grid-a1") + hubFrame("grid-a2"))
        await shared.push(hubFrame("workspace.updated"))
        await laneB.push(hubFrame("grid-b"))

        #expect(try await hubWaitUntil { await collector.frames.count == 4 })
        let scoped = await collector.scopedFrames
        #expect(scoped.filter { $0.frame.hasPrefix("grid-a") }.allSatisfy { $0.scope == surfaceA })
        #expect(scoped.first { $0.frame == "grid-b" }?.scope == surfaceB)
        #expect(scoped.first { $0.frame == "workspace.updated" }.map { $0.scope == nil } == true)
        await hub.stop()
    }

    @Test func framesSplitAcrossChunksArriveWholeAndInLaneOrder() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }

        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        let surface = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "S"))
        var surfaceBytes = Data()
        for index in 0..<20 { surfaceBytes.append(hubFrame("s\(index)")) }
        var sharedBytes = Data()
        for index in 0..<20 { sharedBytes.append(hubFrame("e\(index)")) }
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
        #expect(try await hubWaitUntil { await collector.frames.count == 40 })
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
        _ = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "1"))
        _ = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "2"))
        let third = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "3"))
        #expect(try await hubWaitUntil { await third.stopCodes == [IrxServerEventLaneHub.laneLimitStopCode] })
        #expect(await hub.activeSurfaceLaneCount() == 2)
        await hub.stop()
    }

    @Test func endedSurfaceLaneFreesItsSlotAndKeepsTheHubAlive() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let collector = FrameCollector()
        let consumer = collect(await hub.subscribe(), into: collector)
        defer { consumer.cancel() }
        let first = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "S"))
        #expect(try await hubWaitUntil { await hub.activeSurfaceLaneCount() == 1 })
        await first.push(hubFrame("partial").prefix(6))
        await first.end()
        #expect(try await hubWaitUntil { await hub.activeSurfaceLaneCount() == 0 })
        // The host reopens the surface on a fresh stream after a failure.
        let reopened = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "S"))
        await reopened.push(hubFrame("full"))
        #expect(try await hubWaitUntil { await collector.frames == ["full"] })
        #expect(await hub.isAlive)
        await hub.stop()
    }

    @Test func replacingTheSubscriberRoutesLaterFramesToTheNewOne() async throws {
        let acceptor = FakeLaneAcceptor()
        let hub = IrxServerEventLaneHub(acceptLane: acceptor.accept)
        let firstCollector = FrameCollector()
        let first = collect(await hub.subscribe(), into: firstCollector)
        let shared = acceptor.open(IrxLaneDescriptor(lane: .events))
        await shared.push(hubFrame("one"))
        #expect(try await hubWaitUntil { await firstCollector.frames == ["one"] })

        let secondCollector = FrameCollector()
        let second = collect(await hub.subscribe(), into: secondCollector)
        defer { second.cancel() }
        await first.value
        await shared.push(hubFrame("two"))
        #expect(try await hubWaitUntil { await secondCollector.frames == ["two"] })
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
        let bad = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "bad"))
        let good = acceptor.open(IrxSurfaceEventLaneProtocol().descriptor(surfaceID: "good"))
        await bad.push(hubFrame(String(repeating: "x", count: 64)))
        await good.push(hubFrame("ok"))
        #expect(try await hubWaitUntil { await bad.stopCodes == [IrxServerEventLaneHub.malformedFrameStopCode] })
        #expect(try await hubWaitUntil { await collector.frames == ["ok"] })
        await hub.stop()
    }
}

