import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Test func terminalLaneResumesOnlyAfterReplayAcknowledgement() async throws {
    let surfaceID = RoutingHostRouter.terminalA
    let firstLane = ReplayBarrierTestLane(sequence: 0, bytes: "old")
    let secondLane = ReplayBarrierTestLane(sequence: 5, bytes: "")
    let provider = ReplayBarrierTestLaneProvider(lanes: [firstLane, secondLane])
    let router = RoutingHostRouter()
    let store = try await makeRoutingConnectedStore(
        router: router,
        routeKind: .iroh,
        terminalLaneProvider: { _, _, cursor in
            try await provider.open(cursor: cursor)
        }
    )
    let output = store.terminalOutputStream(surfaceID: surfaceID)
    defer { withExtendedLifetime(output) {} }
    var iterator = output.makeAsyncIterator()
    let barrier = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    // Hold the authoritative request while the independent lane arrives.
    store.terminalReplaySurfaceIDsInFlight.insert(surfaceID)
    store.terminalReplayBarrierTokensInFlightBySurfaceID[surfaceID] = barrier

    for _ in 0..<1_000 {
        if await firstLane.closeCount() == 1 { break }
        await Task.yield()
    }
    #expect(await firstLane.closeCount() == 1)
    #expect(await provider.cursors() == [nil])

    #expect(store.deliverTerminalBytes(
        Data("fresh".utf8),
        surfaceID: surfaceID,
        endSequence: 5,
        bypassReplayBarrier: true
    ))
    store.terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID[surfaceID] =
        store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID]
    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 5)
    let replay = try #require(await iterator.next())
    for _ in 0..<100 { await Task.yield() }
    #expect(await provider.cursors() == [nil])
    #expect(!store.terminalLaneOutputReadySurfaceIDs.contains(surfaceID))

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replay.streamToken)
    for _ in 0..<1_000 {
        if store.terminalLaneOutputReadySurfaceIDs.contains(surfaceID) { break }
        await Task.yield()
    }
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    #expect(await provider.cursors() == [nil, 5])
    #expect(store.terminalLaneOutputReadySurfaceIDs.contains(surfaceID))

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: surfaceID)
    #expect(await secondLane.inputs() == ["a"])
    #expect(await router.recordedTerminalInputs().isEmpty)
    await store.terminalLaneCoordinator?.deactivateAll()
}

private actor ReplayBarrierTestLane: MobileTerminalLaneConnection {
    private var pendingFrame: MobileTerminalLaneOutputFrame?
    private var waiter: CheckedContinuation<MobileTerminalLaneOutputFrame?, Never>?
    private var closedCount = 0
    private var sentInputs: [String] = []

    init(sequence: UInt64, bytes: String) {
        let data = Data(bytes.utf8)
        pendingFrame = MobileTerminalLaneOutputFrame(
            kind: .replay,
            retainedBaseSequence: sequence,
            sequence: sequence,
            currentSequence: sequence + UInt64(data.count),
            bytes: data
        )
    }

    func receiveOutput() async -> MobileTerminalLaneOutputFrame? {
        if let frame = pendingFrame {
            pendingFrame = nil
            return frame
        }
        if closedCount > 0 { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func sendInput(_ input: String) { sentInputs.append(input) }

    func close() {
        closedCount += 1
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func closeCount() -> Int { closedCount }
    func inputs() -> [String] { sentInputs }
}

private actor ReplayBarrierTestLaneProvider {
    private let lanes: [ReplayBarrierTestLane]
    private var requestedCursors: [UInt64?] = []

    init(lanes: [ReplayBarrierTestLane]) { self.lanes = lanes }

    func open(cursor: UInt64?) throws -> any MobileTerminalLaneConnection {
        let index = requestedCursors.count
        requestedCursors.append(cursor)
        guard index < lanes.count else { throw CancellationError() }
        return lanes[index]
    }

    func cursors() -> [UInt64?] { requestedCursors }
}
