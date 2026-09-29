import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrxTransport

// MARK: - Fakes

/// In-memory lane write half. A blocked lane accepts no bytes until the test
/// releases it, like a QUIC stream out of flow credit. Like iroh-ffi, every
/// other call on the stream (priority, finish, reset) waits for an in-flight
/// write to finish, because the native stream sits behind one lock.
actor FakeEventLaneWriter: IrxEventLaneWriting {
    let descriptor: IrxLaneDescriptor
    private let blocked: Bool
    private var blocksNextPriority: Bool
    private var blockedWrite: CheckedContinuation<Void, any Error>?
    private var blockedPriorityWaiter: CheckedContinuation<Void, Never>?
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var written: [Data] = []
    private(set) var priorities: [Int32] = []
    private(set) var finished = false
    private(set) var resetCodes: [UInt64] = []

    init(descriptor: IrxLaneDescriptor, blocked: Bool, blockedPriority: Bool = false) {
        self.descriptor = descriptor
        self.blocked = blocked
        self.blocksNextPriority = blockedPriority
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
        if blocksNextPriority {
            blocksNextPriority = false
            await withCheckedContinuation { blockedPriorityWaiter = $0 }
        }
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

    var isPriorityBlocked: Bool { blockedPriorityWaiter != nil }

    func releaseBlockedPriority() {
        blockedPriorityWaiter?.resume()
        blockedPriorityWaiter = nil
    }

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

actor FakeLaneOpener {
    private(set) var opened: [FakeEventLaneWriter] = []
    var blockedSurfaces: Set<String> = []
    var blockedPrioritySurfaces: Set<String> = []

    func block(_ surfaceID: String) { blockedSurfaces.insert(surfaceID) }
    func unblock(_ surfaceID: String) { blockedSurfaces.remove(surfaceID) }
    func blockPriority(_ surfaceID: String) { blockedPrioritySurfaces.insert(surfaceID) }

    func open(_ descriptor: IrxLaneDescriptor) -> any IrxEventLaneWriting {
        let surfaceID = IrxSurfaceEventLaneProtocol().surfaceID(of: descriptor) ?? ""
        let writer = FakeEventLaneWriter(
            descriptor: descriptor,
            blocked: blockedSurfaces.contains(surfaceID),
            blockedPriority: blockedPrioritySurfaces.contains(surfaceID)
        )
        opened.append(writer)
        return writer
    }

    func writers(surfaceID: String) -> [FakeEventLaneWriter] {
        opened.filter {
            IrxSurfaceEventLaneProtocol().surfaceID(of: $0.descriptor) == surfaceID
        }
    }
}

/// Keeps every open pending, like a native uni-stream open waiting for the
/// phone to grant more stream credit.
actor PendingLaneOpener {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var openCount = 0
    private(set) var opened: [FakeEventLaneWriter] = []

    func open(_ descriptor: IrxLaneDescriptor) async -> any IrxEventLaneWriting {
        openCount += 1
        await withCheckedContinuation { pending.append($0) }
        let writer = FakeEventLaneWriter(descriptor: descriptor, blocked: false)
        opened.append(writer)
        return writer
    }

    func releaseAll() {
        let waiters = pending
        pending.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor SendOutcomes {
    private(set) var successes = 0
    private(set) var failures = 0

    func record(_ result: Result<Void, any Error>) {
        switch result {
        case .success: successes += 1
        case .failure: failures += 1
        }
    }
}

enum SurfaceLaneSendOutcome: Equatable {
    case completed
    case failed(IrxSurfaceEventLanes.LaneError)
}

func frame(_ text: String) -> Data {
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

func waitUntil(
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

    private func makeLanes(
        _ opener: PendingLaneOpener,
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
        await lanes.noteFocused(surfaceID: "B")
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
            await stalledWriter.resetCodes == [IrxSurfaceEventLanes.stalledResetCode]
        })
    }

    /// A lane waiting for native stream credit must reserve capacity before
    /// suspension; otherwise concurrent sends all pass the limit check.
    @Test func pendingOpensCountTowardTheLaneLimit() async throws {
        let opener = PendingLaneOpener()
        let lanes = IrxSurfaceEventLanes(configuration: .init(maximumLaneCount: 2)) { descriptor in
            await opener.open(descriptor)
        }
        let outcomes = SendOutcomes()
        let surfaceIDs = (0..<5).map { "surface-\($0)" }
        let sends = surfaceIDs.map { surfaceID in
            Task {
                do {
                    try await lanes.send(frame(surfaceID), surfaceID: surfaceID, generation: 0)
                    await outcomes.record(.success(()))
                } catch {
                    await outcomes.record(.failure(error))
                }
            }
        }

        #expect(try await waitUntil {
            let opens = await opener.openCount
            let failures = await outcomes.failures
            return opens + failures == surfaceIDs.count
        })
        #expect(await opener.openCount == 2)
        await opener.releaseAll()
        for send in sends { await send.value }
        #expect(await outcomes.successes == 2)
        await lanes.closeAll()
    }

    @Test func anOlderPendingGenerationCannotReplaceANewerOpen() async throws {
        let opener = PendingLaneOpener()
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 2))
        let old = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("old"), surfaceID: "surface", generation: 0)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.released)
            }
        }
        #expect(try await waitUntil { await opener.openCount == 1 })
        let newer = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("new"), surfaceID: "surface", generation: 1)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.released)
            }
        }
        #expect(try await waitUntil { await opener.openCount == 2 })
        await opener.releaseAll()
        #expect(await old.value == .failed(.released))
        #expect(await newer.value == .completed)
        await lanes.closeAll()
    }

    @Test func timedOutOpenKeepsItsReservedSlotUntilLateNativeOpenRetires() async throws {
        let opener = PendingLaneOpener()
        let lanes = makeLanes(
            opener,
            configuration: .init(maximumLaneCount: 1, openDeadline: .milliseconds(20))
        )
        let timedOut = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("timed-out"), surfaceID: "surface", generation: 0)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.openTimedOut)
            }
        }
        #expect(try await waitUntil { await opener.openCount == 1 })
        #expect(await timedOut.value == SurfaceLaneSendOutcome.failed(.openTimedOut))
        await #expect(throws: IrxSurfaceEventLanes.LaneError.laneLimit) {
            try await lanes.send(frame("retry"), surfaceID: "surface", generation: 1)
        }

        await opener.releaseAll()
        #expect(try await waitUntil {
            guard let writer = await opener.opened.first else { return false }
            return await writer.resetCodes == [IrxSurfaceEventLanes.supersededResetCode]
        })

        let recovered = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("recovered"), surfaceID: "surface", generation: 1)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.laneLimit)
            }
        }
        #expect(try await waitUntil { await opener.openCount == 2 })
        await opener.releaseAll()
        #expect(await recovered.value == SurfaceLaneSendOutcome.completed)
        await lanes.closeAll()
    }

    @Test func prioritySuspensionKeepsItsSlotReserved() async throws {
        let opener = FakeLaneOpener()
        await opener.blockPriority("surface-a")
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 1))
        let first = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("a"), surfaceID: "surface-a", generation: 0)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.laneLimit)
            }
        }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "surface-a").first else { return false }
            return await writer.isPriorityBlocked
        })

        await #expect(throws: IrxSurfaceEventLanes.LaneError.laneLimit) {
            try await lanes.send(frame("b"), surfaceID: "surface-b", generation: 0)
        }
        let writer = try #require(await opener.writers(surfaceID: "surface-a").first)
        await writer.releaseBlockedPriority()
        #expect(await first.value == .completed)
        #expect(await lanes.openSurfaceIDs() == ["surface-a"])
        await lanes.closeAll()
    }

    @Test func releaseDuringPrioritySuspensionQuarantinesTheOpenedStream() async throws {
        let opener = FakeLaneOpener()
        await opener.blockPriority("surface")
        let lanes = makeLanes(opener)
        let opening = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("old"), surfaceID: "surface", generation: 0)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.released)
            }
        }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "surface").first else { return false }
            return await writer.isPriorityBlocked
        })

        await lanes.release(surfaceID: "surface", belowGeneration: 1)
        #expect(await lanes.openSurfaceIDs().isEmpty)
        let writer = try #require(await opener.writers(surfaceID: "surface").first)
        await writer.releaseBlockedPriority()
        #expect(await opening.value == .failed(.released))
        #expect(await lanes.openSurfaceIDs().isEmpty)
        #expect(await writer.resetCodes == [IrxSurfaceEventLanes.releasedResetCode])
        await lanes.closeAll()
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

    @Test func laneCountRefusesANewSurfaceInsteadOfEvictingAnother() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 2))
        try await lanes.send(frame("1"), surfaceID: "one", generation: 0)
        try await lanes.send(frame("2"), surfaceID: "two", generation: 0)
        await #expect(throws: IrxSurfaceEventLanes.LaneError.laneLimit) {
            try await lanes.send(frame("3"), surfaceID: "three", generation: 0)
        }
        #expect(await lanes.openSurfaceIDs() == ["one", "two"])
        await lanes.closeAll()
    }

    @Test func releasedSurfaceRejectsStaleGenerationBeforeOpening() async throws {
        let opener = FakeLaneOpener()
        let lanes = makeLanes(opener)
        try await lanes.send(frame("old"), surfaceID: "surface", generation: 0)
        await lanes.release(surfaceID: "surface", belowGeneration: 1)
        await #expect(throws: IrxSurfaceEventLanes.LaneError.released) {
            try await lanes.send(frame("stale"), surfaceID: "surface", generation: 0)
        }
        try await lanes.send(frame("new"), surfaceID: "surface", generation: 1)
        #expect(await opener.writers(surfaceID: "surface").count == 2)
        await lanes.closeAll()
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
        let descriptor = IrxSurfaceEventLaneProtocol().descriptor(surfaceID: " ABC-def ")
        #expect(descriptor.lane == .events)
        #expect(IrxSurfaceEventLaneProtocol().surfaceID(of: descriptor) == "abc-def")
        #expect(IrxSurfaceEventLaneProtocol().surfaceID(of: IrxLaneDescriptor(lane: .events)) == nil)
        #expect(IrxSurfaceEventLaneProtocol().surfaceID(
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
