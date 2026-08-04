import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileTerminalLaneCoordinatorTests {
    @Test
    func replayActivatesIndependentInputAndCancellationReturnsToFallback() async throws {
        let lane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 5, bytes: "abc")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let readiness = TerminalLaneReadinessRecorder()
        var readinessIterator = await readiness.stream().makeAsyncIterator()
        let consumed = TerminalLaneFrameRecorder()

        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { 5 },
            consume: { frame in
                await consumed.append(frame)
                return .accepted(outputReady: true)
            },
            readinessChanged: { await readiness.append($0) }
        ))

        #expect(await readinessIterator.next() == true)
        #expect(await coordinator.sendInput("echo ok\n", surfaceID: Self.surfaceID) == .sent)
        #expect(await lane.inputs() == ["echo ok\n"])
        #expect(await consumed.frames().map(\.sequence) == [5])

        await coordinator.deactivate(surfaceID: Self.surfaceID)

        #expect(await readinessIterator.next() == false)
        #expect(await lane.closeCount() == 1)
        #expect(await coordinator.sendInput("fallback", surfaceID: Self.surfaceID) == .unavailable)
    }

    @Test
    func sequenceGapSuspendsUntilAuthoritativeCursorThenReopens() async throws {
        let firstLane = TerminalLaneTestConnection(
            frames: [
                Self.frame(kind: .replay, sequence: 5, bytes: "abc"),
                Self.frame(kind: .chunk, sequence: 10, bytes: "gap"),
            ],
            waitsAfterFrames: true
        )
        let secondLane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 10, bytes: "next")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [firstLane, secondLane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let cursor = TerminalLaneCursor(value: 5)
        let readiness = TerminalLaneReadinessRecorder()
        var readinessIterator = await readiness.stream().makeAsyncIterator()

        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { await cursor.value() },
            consume: { frame in
                frame.sequence == 10 && frame.kind == .chunk
                    ? .suspendUntilAuthoritativeOutput
                    : .accepted(outputReady: true)
            },
            readinessChanged: { await readiness.append($0) }
        ))

        #expect(await readinessIterator.next() == true)
        #expect(await readinessIterator.next() == false)
        #expect(await firstLane.closeCount() == 1)

        await cursor.setValue(10)
        await coordinator.resume(surfaceID: Self.surfaceID)

        #expect(await readinessIterator.next() == true)
        #expect(await provider.requestedCursors() == [5, 10])
        await coordinator.deactivateAll()
    }

    @Test
    func replayCursorMismatchNeverBecomesReadyOrAcceptsInput() async throws {
        let mismatchedLane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 7, bytes: "bad")],
            waitsAfterFrames: false
        )
        let provider = TerminalLaneTestProvider(lanes: [mismatchedLane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let readiness = TerminalLaneReadinessRecorder()

        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { 5 },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { await readiness.append($0) }
        ))

        await provider.waitUntilExhausted()
        #expect(await coordinator.isOutputReady(surfaceID: Self.surfaceID) == false)
        #expect(await coordinator.sendInput("must-fallback", surfaceID: Self.surfaceID) == .unavailable)
        #expect(await readiness.values().isEmpty)
        await coordinator.deactivateAll()
    }

    private static let surfaceID = "123e4567-e89b-42d3-a456-426614174000"

    private static func frame(
        kind: MobileTerminalLaneOutputFrame.Kind,
        sequence: UInt64,
        bytes: String
    ) -> MobileTerminalLaneOutputFrame {
        let data = Data(bytes.utf8)
        return MobileTerminalLaneOutputFrame(
            kind: kind,
            retainedBaseSequence: sequence,
            sequence: sequence,
            currentSequence: sequence + UInt64(data.count),
            bytes: data
        )
    }

    private static func request() throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(
                    identity: try CmxIrohPeerIdentity(
                        endpointID: String(repeating: "a", count: 64)
                    ),
                    pathHints: []
                )
            ),
            expectedPeerDeviceID: "mac",
            authorizationMode: .transportAdmission
        )
    }

    private static func configuration(
        providerRequest: CmxByteTransportRequest,
        cursor: @escaping @Sendable () async -> UInt64?,
        consume: @escaping @Sendable (MobileTerminalLaneOutputFrame) async -> MobileTerminalLaneCoordinator.FrameDisposition,
        readinessChanged: @escaping @Sendable (Bool) async -> Void
    ) -> MobileTerminalLaneCoordinator.Configuration {
        MobileTerminalLaneCoordinator.Configuration(
            request: providerRequest,
            surfaceID: surfaceID,
            cursor: cursor,
            consume: consume,
            readinessChanged: readinessChanged
        )
    }
}

private actor TerminalLaneTestConnection: MobileTerminalLaneConnection {
    private var pendingFrames: [MobileTerminalLaneOutputFrame]
    private let waitsAfterFrames: Bool
    private var waiter: CheckedContinuation<MobileTerminalLaneOutputFrame?, Never>?
    private var sentInputs: [String] = []
    private var closes = 0
    private var closed = false

    init(frames: [MobileTerminalLaneOutputFrame], waitsAfterFrames: Bool) {
        self.pendingFrames = frames
        self.waitsAfterFrames = waitsAfterFrames
    }

    func receiveOutput() async -> MobileTerminalLaneOutputFrame? {
        if !pendingFrames.isEmpty { return pendingFrames.removeFirst() }
        guard waitsAfterFrames else { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func sendInput(_ input: String) {
        sentInputs.append(input)
    }

    func close() {
        guard !closed else { return }
        closed = true
        closes += 1
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func inputs() -> [String] { sentInputs }
    func closeCount() -> Int { closes }
}

private actor TerminalLaneTestProvider {
    enum ProviderError: Error { case exhausted }

    private var lanes: [TerminalLaneTestConnection]
    private var cursors: [UInt64?] = []
    private var exhaustionWaiters: [CheckedContinuation<Void, Never>] = []

    init(lanes: [TerminalLaneTestConnection]) {
        self.lanes = lanes
    }

    func callAsFunction(
        _: CmxByteTransportRequest,
        _: String,
        cursor: UInt64?
    ) throws -> any MobileTerminalLaneConnection {
        cursors.append(cursor)
        guard !lanes.isEmpty else {
            for waiter in exhaustionWaiters { waiter.resume() }
            exhaustionWaiters.removeAll()
            throw ProviderError.exhausted
        }
        return lanes.removeFirst()
    }

    func requestedCursors() -> [UInt64?] { cursors }

    func waitUntilExhausted() async {
        if lanes.isEmpty, cursors.count >= 2 { return }
        await withCheckedContinuation { continuation in
            exhaustionWaiters.append(continuation)
        }
    }
}

private actor TerminalLaneReadinessRecorder {
    private var recordedValues: [Bool] = []
    private var continuation: AsyncStream<Bool>.Continuation?

    func stream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func append(_ value: Bool) {
        recordedValues.append(value)
        continuation?.yield(value)
    }

    func values() -> [Bool] { recordedValues }
}

private actor TerminalLaneFrameRecorder {
    private var recordedFrames: [MobileTerminalLaneOutputFrame] = []

    func append(_ frame: MobileTerminalLaneOutputFrame) {
        recordedFrames.append(frame)
    }

    func frames() -> [MobileTerminalLaneOutputFrame] { recordedFrames }
}

private actor TerminalLaneCursor {
    private var storedValue: UInt64?

    init(value: UInt64?) {
        self.storedValue = value
    }

    func value() -> UInt64? { storedValue }
    func setValue(_ value: UInt64?) { storedValue = value }
}
