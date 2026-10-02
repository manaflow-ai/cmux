import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileTerminalLaneCoordinatorTests {
    @Test
    func sameSurfaceOnAnotherPeerMovesInputWithoutClosingFirstPeer() async throws {
        let firstLane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 0, bytes: "")],
            waitsAfterFrames: true
        )
        let secondLane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 0, bytes: "")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [firstLane, secondLane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }

        let firstReadiness = TerminalLaneReadinessRecorder()
        var firstReadinessIterator = await firstReadiness.stream()
            .makeAsyncIterator()
        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(
                peerDeviceID: "mac-a",
                endpointCharacter: "a"
            ),
            cursor: { nil },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { await firstReadiness.append($0) }
        ))
        #expect(await firstReadinessIterator.next() == true)

        let secondReadiness = TerminalLaneReadinessRecorder()
        var secondReadinessIterator = await secondReadiness.stream()
            .makeAsyncIterator()
        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(
                peerDeviceID: "mac-b",
                endpointCharacter: "b"
            ),
            cursor: { nil },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { await secondReadiness.append($0) }
        ))
        #expect(await secondReadinessIterator.next() == true)

        let inputResult = await coordinator.sendInput(
            "second peer",
            surfaceID: Self.surfaceID
        )

        #expect(await provider.requestCount() == 2)
        #expect(inputResult == .sent)
        #expect(await firstLane.inputs().isEmpty)
        #expect(await secondLane.inputs() == ["second peer"])
        #expect(await firstLane.closeCount() == 0)
        await coordinator.deactivateAll()
    }

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
    func inputOnlyLaneDoesNotValidateAgainstOutputCursor() async throws {
        let lane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 12, bytes: "")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let readiness = TerminalLaneReadinessRecorder()
        var readinessIterator = await readiness.stream().makeAsyncIterator()

        await coordinator.ensure(Self.configuration(
            mode: .inputOnly,
            providerRequest: try Self.request(),
            cursor: { 5 },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { await readiness.append($0) }
        ))

        #expect(await readinessIterator.next() == true)
        #expect(await provider.requestedCursors() == [nil])
        #expect(await coordinator.sendInput("echo fast\\n", surfaceID: Self.surfaceID) == .sent)
        await coordinator.deactivateAll()
    }

    @Test
    func outputLaneDoesNotFallBackToInputOnlyProvider() async throws {
        let outputProvider = TerminalLaneTestProvider(lanes: [])
        let inputProvider = TerminalLaneTestProvider(lanes: [
            TerminalLaneTestConnection(
                frames: [Self.frame(kind: .replay, sequence: 0, bytes: "")],
                waitsAfterFrames: true
            ),
        ])
        let coordinator = MobileTerminalLaneCoordinator(
            provider: { request, surfaceID, cursor in
                try await outputProvider.callAsFunction(request, surfaceID, cursor: cursor)
            },
            inputOnlyProvider: { request, surfaceID, cursor in
                try await inputProvider.callAsFunction(request, surfaceID, cursor: cursor)
            }
        )

        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { nil },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { _ in }
        ))
        // The output provider is the causal completion signal. Its empty lane
        // list makes the request fail after recording the attempted selection.
        await outputProvider.waitUntilRequested()

        #expect(await outputProvider.requestCount() > 0)
        #expect(await inputProvider.requestCount() == 0)
        await coordinator.deactivateAll()
        #expect(await coordinator.isOutputReady(surfaceID: Self.surfaceID) == false)
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
    func consumerBackpressureSuspendsBeforeDrainingNextChunk() async throws {
        let firstLane = TerminalLaneTestConnection(
            frames: [
                Self.frame(kind: .replay, sequence: 0, bytes: "baseline"),
                Self.frame(kind: .chunk, sequence: 8, bytes: "must-not-drain"),
            ],
            waitsAfterFrames: true
        )
        let secondLane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 0, bytes: "baseline")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [firstLane, secondLane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let readiness = TerminalLaneReadinessRecorder()
        var readinessIterator = await readiness.stream().makeAsyncIterator()
        let consumed = TerminalLaneFrameRecorder()
        let shouldRejectFirstFrame = TerminalLaneFlag(value: true)

        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { nil },
            consume: { frame in
                await consumed.append(frame)
                if await shouldRejectFirstFrame.value() {
                    await shouldRejectFirstFrame.setValue(false)
                    return .accepted(outputReady: false)
                }
                return .accepted(outputReady: true)
            },
            readinessChanged: { await readiness.append($0) }
        ))

        for _ in 0..<100 {
            if await firstLane.closeCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await firstLane.closeCount() == 1)
        #expect(await consumed.frames().map(\.kind) == [.replay])

        await coordinator.resume(surfaceID: Self.surfaceID)
        #expect(await readinessIterator.next() == true)
        #expect(await consumed.frames().map(\.kind) == [.replay, .replay])
        #expect(await provider.requestCount() == 2)
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

    private static func request(
        peerDeviceID: String = "mac",
        endpointCharacter: Character = "a"
    ) throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(
                    identity: try CmxIrohPeerIdentity(
                        endpointID: String(
                            repeating: String(endpointCharacter),
                            count: 64
                        )
                    ),
                    pathHints: []
                )
            ),
            expectedPeerDeviceID: peerDeviceID,
            authorizationMode: .transportAdmission
        )
    }

    @Test
    func acknowledgementsReachTheSenderAndNeverTheOutputConsumer() async throws {
        let acknowledgement = MobileTerminalInputAcknowledgement(
            status: .applied,
            streamID: UUID(),
            sequence: 4
        )
        let lane = TerminalLaneTestConnection(
            frames: [
                Self.frame(kind: .replay, sequence: 0, bytes: ""),
                .inputAcknowledgement(acknowledgement),
                Self.frame(kind: .chunk, sequence: 0, bytes: "ok"),
            ],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let consumed = TerminalLaneFrameRecorder()
        let acknowledged = TerminalLaneAcknowledgementRecorder()
        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { 0 },
            consume: { frame in
                await consumed.append(frame)
                return .accepted(outputReady: true)
            },
            readinessChanged: { _ in },
            acknowledged: { await acknowledged.append($0) }
        ))
        #expect(await acknowledged.waitForCount(1) == [acknowledgement])
        #expect(await consumed.waitForFrameCount(2).map(\.kind) == [.replay, .chunk])
        await coordinator.deactivateAll()
    }

    @Test
    func identifiedInputOnlyTravelsOnItsOwnTerminalsLane() async throws {
        let lane = TerminalLaneTestConnection(
            frames: [Self.frame(kind: .replay, sequence: 0, bytes: "")],
            waitsAfterFrames: true
        )
        let provider = TerminalLaneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.callAsFunction(request, surfaceID, cursor: cursor)
        }
        let readiness = TerminalLaneReadinessRecorder()
        var readinessIterator = await readiness.stream().makeAsyncIterator()
        await coordinator.ensure(Self.configuration(
            providerRequest: try Self.request(),
            cursor: { nil },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { await readiness.append($0) }
        ))
        #expect(await readinessIterator.next() == true)

        let own = MobileTerminalInputDelivery(
            surfaceID: try #require(UUID(uuidString: Self.surfaceID)),
            streamID: UUID(),
            sequence: 1
        )
        let foreign = MobileTerminalInputDelivery(surfaceID: UUID(), streamID: UUID(), sequence: 1)
        #expect(await coordinator.sendInput("mine", surfaceID: Self.surfaceID, delivery: own) == .sent)
        #expect(await coordinator.sendInput("theirs", surfaceID: Self.surfaceID, delivery: foreign) == .unavailable)
        #expect(await lane.identifiedInputs().map(\.text) == ["mine"])
        #expect(await lane.identifiedInputs().map(\.delivery) == [own])
        await coordinator.deactivateAll()
    }

    private static func configuration(
        mode: MobileTerminalLaneCoordinator.LaneMode = .output,
        providerRequest: CmxByteTransportRequest,
        cursor: @escaping @Sendable () async -> UInt64?,
        consume: @escaping @Sendable (MobileTerminalLaneOutputFrame) async -> MobileTerminalLaneCoordinator.FrameDisposition,
        readinessChanged: @escaping @Sendable (Bool) async -> Void,
        acknowledged: @escaping @Sendable (MobileTerminalInputAcknowledgement) async -> Void = { _ in }
    ) -> MobileTerminalLaneCoordinator.Configuration {
        MobileTerminalLaneCoordinator.Configuration(
            request: providerRequest,
            surfaceID: surfaceID,
            mode: mode,
            cursor: cursor,
            consume: consume,
            readinessChanged: readinessChanged,
            acknowledged: acknowledged
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

    private var sentIdentifiedInputs: [(text: String, delivery: MobileTerminalInputDelivery)] = []

    func sendInput(
        _ input: String,
        sequence: UInt64?,
        delivery: MobileTerminalInputDelivery
    ) {
        sentIdentifiedInputs.append((input, delivery))
    }

    func identifiedInputs() -> [(text: String, delivery: MobileTerminalInputDelivery)] {
        sentIdentifiedInputs
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
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
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
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        guard !lanes.isEmpty else {
            for waiter in exhaustionWaiters { waiter.resume() }
            exhaustionWaiters.removeAll()
            throw ProviderError.exhausted
        }
        return lanes.removeFirst()
    }

    func requestedCursors() -> [UInt64?] { cursors }
    func requestCount() -> Int { cursors.count }

    func waitUntilRequested() async {
        if !cursors.isEmpty { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

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
    private var waiters: [(Int, CheckedContinuation<[MobileTerminalLaneOutputFrame], Never>)] = []

    func append(_ frame: MobileTerminalLaneOutputFrame) {
        recordedFrames.append(frame)
        let ready = waiters.filter { recordedFrames.count >= $0.0 }
        waiters.removeAll { recordedFrames.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume(returning: recordedFrames) }
    }

    func frames() -> [MobileTerminalLaneOutputFrame] { recordedFrames }

    func waitForFrameCount(_ count: Int) async -> [MobileTerminalLaneOutputFrame] {
        if recordedFrames.count >= count { return recordedFrames }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor TerminalLaneCursor {
    private var storedValue: UInt64?

    init(value: UInt64?) {
        self.storedValue = value
    }

    func value() -> UInt64? { storedValue }
    func setValue(_ value: UInt64?) { storedValue = value }
}

private actor TerminalLaneFlag {
    private var storedValue: Bool

    init(value: Bool) {
        self.storedValue = value
    }

    func value() -> Bool { storedValue }
    func setValue(_ value: Bool) { storedValue = value }
}

private actor TerminalLaneAcknowledgementRecorder {
    private var recorded: [MobileTerminalInputAcknowledgement] = []
    private var waiters: [(Int, CheckedContinuation<[MobileTerminalInputAcknowledgement], Never>)] = []

    func append(_ acknowledgement: MobileTerminalInputAcknowledgement) {
        recorded.append(acknowledgement)
        let ready = waiters.filter { recorded.count >= $0.0 }
        waiters.removeAll { recorded.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume(returning: recorded) }
    }

    func waitForCount(_ count: Int) async -> [MobileTerminalInputAcknowledgement] {
        if recorded.count >= count { return recorded }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
