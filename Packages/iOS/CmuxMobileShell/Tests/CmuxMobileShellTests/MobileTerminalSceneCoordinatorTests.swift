import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileTerminalSceneCoordinatorTests {
    @Test
    func consumerBackpressureAndFullPresentationGateInputReadiness() async throws {
        let lane = TerminalSceneTestConnection(
            envelopes: [
                Self.configurationEnvelope(),
                Self.sceneEnvelope(),
                Self.accessibilityEnvelope(),
            ],
            waitsAfterEnvelopes: true
        )
        let provider = TerminalSceneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let gate = TerminalSceneConsumerGate()
        var started = await gate.startedStream().makeAsyncIterator()

        let token = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: UUID(),
            consume: { envelope in
                await gate.consume(envelope)
            },
            finished: { _, _ in }
        ))

        #expect(await started.next() == 1)
        #expect(await lane.receiveCount() == 1)
        #expect(await coordinator.sendInput(Data("early".utf8), surfaceID: Self.surfaceID) == .queued)
        #expect(await lane.inputs().isEmpty)

        await gate.releaseOne()
        #expect(await started.next() == 2)
        #expect(await lane.receiveCount() == 2)
        #expect(await coordinator.sendInput(Data("still early".utf8), surfaceID: Self.surfaceID) == .queued)
        #expect(await lane.inputs().isEmpty)

        await gate.releaseOne()
        #expect(await started.next() == 3)
        #expect(await lane.receiveCount() == 3)
        #expect(await coordinator.sendInput(Data("not presented".utf8), surfaceID: Self.surfaceID) == .queued)
        #expect(await lane.inputs().isEmpty)

        await gate.releaseOne()
        #expect(await waitForInputCount(lane, count: 3))
        #expect(await coordinator.sendInput(Data("ready".utf8), surfaceID: Self.surfaceID) == .sent)
        #expect(await lane.inputs() == [
            Data("early".utf8),
            Data("still early".utf8),
            Data("not presented".utf8),
            Data("ready".utf8),
        ])

        await coordinator.deactivate(surfaceID: Self.surfaceID, token: token)
        #expect(await lane.closeCount() == 1)
        #expect(await coordinator.sendInput(Data("closed".utf8), surfaceID: Self.surfaceID) == .unavailable)
    }

    @Test
    func rejectedGeometryPairDoesNotGrantInputUntilALaterFrameIsPresented() async throws {
        let lane = TerminalSceneTestConnection(
            envelopes: [
                Self.configurationEnvelope(),
                Self.sceneEnvelope(),
                Self.accessibilityEnvelope(),
                Self.sceneEnvelope(contentSequence: 12, presentationSequence: 2),
                Self.accessibilityEnvelope(contentSequence: 12, presentationSequence: 2),
            ],
            waitsAfterEnvelopes: true
        )
        let provider = TerminalSceneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let gate = TerminalSceneConsumerGate(presentedContentSequences: [12])
        var started = await gate.startedStream().makeAsyncIterator()

        let token = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: UUID(),
            consume: { envelope in await gate.consume(envelope) },
            finished: { _, _ in }
        ))

        for expected in 1 ... 3 {
            #expect(await started.next() == expected)
            #expect(await coordinator.sendInput(Data("early".utf8), surfaceID: Self.surfaceID) == .queued)
            #expect(await lane.inputs().isEmpty)
            await gate.releaseOne()
        }
        #expect(await started.next() == 4)
        #expect(await coordinator.sendInput(Data("mismatched".utf8), surfaceID: Self.surfaceID) == .queued)
        #expect(await lane.inputs().isEmpty)
        await gate.releaseOne()
        #expect(await started.next() == 5)
        #expect(await coordinator.sendInput(Data("not yet visible".utf8), surfaceID: Self.surfaceID) == .queued)
        #expect(await lane.inputs().isEmpty)
        await gate.releaseOne()

        #expect(await waitForInputCount(lane, count: 5))
        #expect(await coordinator.sendInput(Data("visible".utf8), surfaceID: Self.surfaceID) == .sent)
        #expect(await lane.inputs() == [
            Data("early".utf8),
            Data("early".utf8),
            Data("early".utf8),
            Data("mismatched".utf8),
            Data("not yet visible".utf8),
            Data("visible".utf8),
        ])
        await coordinator.deactivate(surfaceID: Self.surfaceID, token: token)
    }

    @Test
    func prePresentationInputQueueIsBoundedAndNeverFallsThrough() async throws {
        let lane = TerminalSceneTestConnection(
            envelopes: [Self.configurationEnvelope()],
            waitsAfterEnvelopes: true
        )
        let provider = TerminalSceneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let gate = TerminalSceneConsumerGate()
        var started = await gate.startedStream().makeAsyncIterator()
        let token = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: UUID(),
            consume: { envelope in await gate.consume(envelope) },
            finished: { _, _ in }
        ))
        #expect(await started.next() == 1)

        let bound = Data(repeating: 0x61, count: 256 * 1_024)
        #expect(await coordinator.sendInput(bound, surfaceID: Self.surfaceID) == .queued)
        #expect(await coordinator.sendInput(Data([0x62]), surfaceID: Self.surfaceID) == .failed)
        #expect(await lane.inputs().isEmpty)

        await gate.releaseOne()
        await coordinator.deactivate(surfaceID: Self.surfaceID, token: token)
    }

    @Test
    func replacedLaneCannotDeliverIntoTheNewPresentationConsumer() async throws {
        let staleLane = TerminalSceneTestConnection(
            envelopes: [],
            waitsAfterEnvelopes: true,
            closeUnblocksReceive: false
        )
        let currentLane = TerminalSceneTestConnection(
            envelopes: [
                Self.configurationEnvelope(
                    terminalID: Self.currentTerminalID,
                    generation: 2
                ),
                Self.sceneEnvelope(
                    terminalID: Self.currentTerminalID,
                    generation: 2
                ),
                Self.accessibilityEnvelope(
                    terminalID: Self.currentTerminalID,
                    generation: 2
                ),
            ],
            waitsAfterEnvelopes: true
        )
        let provider = TerminalSceneTestProvider(lanes: [staleLane, currentLane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let recorder = TerminalSceneEnvelopeRecorder()
        var counts = await recorder.countStream().makeAsyncIterator()

        _ = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: UUID(),
            consume: { _ in
                Issue.record("replaced scene consumer received an envelope")
                return false
            },
            finished: { _, _ in }
        ))
        let currentToken = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(generation: 2),
            lifecycleID: UUID(),
            consume: { envelope in
                await recorder.append(envelope)
            },
            finished: { _, _ in }
        ))

        await staleLane.enqueue(Self.configurationEnvelope())
        #expect(await counts.next() == 1)
        #expect(await counts.next() == 2)
        #expect(await counts.next() == 3)
        #expect(await recorder.terminalIDs() == [
            Self.currentTerminalID,
            Self.currentTerminalID,
            Self.currentTerminalID,
        ])
        #expect(await staleLane.closeCount() == 1)

        await coordinator.deactivate(surfaceID: Self.surfaceID, token: currentToken)
    }

    @Test
    func delayedOldLifecycleTeardownCannotCloseAReconnectedPresentation() async throws {
        let oldLane = TerminalSceneTestConnection(
            envelopes: [],
            waitsAfterEnvelopes: true
        )
        let currentLane = TerminalSceneTestConnection(
            envelopes: [],
            waitsAfterEnvelopes: true
        )
        let provider = TerminalSceneTestProvider(lanes: [oldLane, currentLane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let oldLifecycleID = UUID()
        let currentLifecycleID = UUID()

        _ = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: oldLifecycleID,
            consume: { _ in false },
            finished: { _, _ in }
        ))
        let currentToken = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(generation: 2),
            lifecycleID: currentLifecycleID,
            consume: { _ in false },
            finished: { _, _ in }
        ))

        await coordinator.deactivateAll(lifecycleID: oldLifecycleID)

        #expect(await currentLane.closeCount() == 0)
        #expect(
            await coordinator.sendInput(
                Data("reconnected".utf8),
                surfaceID: Self.surfaceID
            ) == .queued
        )

        await coordinator.deactivate(
            surfaceID: Self.surfaceID,
            token: currentToken
        )
        #expect(await currentLane.closeCount() == 1)
    }

    @Test
    func orderlyLaneEndRemovesInputAuthorityAndReportsTypedTermination() async throws {
        let lane = TerminalSceneTestConnection(
            envelopes: [
                Self.configurationEnvelope(),
                Self.sceneEnvelope(),
                Self.accessibilityEnvelope(),
            ],
            waitsAfterEnvelopes: false
        )
        let provider = TerminalSceneTestProvider(lanes: [lane])
        let coordinator = MobileTerminalSceneCoordinator { request, scene in
            try await provider.callAsFunction(request, scene)
        }
        let terminations = TerminalSceneTerminationRecorder()
        var values = await terminations.stream().makeAsyncIterator()

        _ = try await coordinator.activate(.init(
            request: try Self.transportRequest(),
            scene: Self.request(),
            lifecycleID: UUID(),
            consume: { envelope in
                if case .accessibility = envelope { return true }
                return false
            },
            finished: { token, termination in
                await terminations.append(token: token, termination: termination)
            }
        ))

        let termination = await values.next()
        #expect(termination?.termination == .ended)
        #expect(await lane.closeCount() == 1)
        #expect(await coordinator.sendInput(Data("late".utf8), surfaceID: Self.surfaceID) == .unavailable)
    }

    private static let surfaceID = "123e4567-e89b-42d3-a456-426614174000"
    private static let terminalID = UUID(uuidString: surfaceID)!
    private static let currentTerminalID =
        UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private static let presentationID =
        UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private static func request(generation: UInt64 = 1) -> MobileTerminalSceneRequest {
        MobileTerminalSceneRequest(
            surfaceID: surfaceID,
            presentationID: presentationID,
            presentationGeneration: generation,
            width: 1_170,
            height: 2_532,
            contentScale: 3
        )
    }

    private static func configurationEnvelope(
        terminalID: UUID? = nil,
        generation: UInt64 = 1
    ) -> MobileTerminalSceneEnvelope {
        let terminalID = terminalID ?? Self.terminalID
        return .configuration(MobileTerminalSceneConfiguration(
            terminalID: terminalID,
            terminalEpoch: 7,
            presentationID: presentationID,
            presentationGeneration: generation,
            rendererConfigRevision: 3,
            width: 1_170,
            height: 2_532,
            contentScale: 3,
            rendererConfig: Data("font-size = 13\n".utf8)
        ))
    }

    private static func sceneEnvelope(
        terminalID: UUID? = nil,
        generation: UInt64 = 1,
        contentSequence: UInt64 = 11,
        presentationSequence: UInt64 = 1
    ) -> MobileTerminalSceneEnvelope {
        let terminalID = terminalID ?? Self.terminalID
        return .scene(MobileTerminalSceneFrame(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence,
            presentationID: presentationID,
            presentationGeneration: generation,
            presentationSequence: presentationSequence,
            kind: .full,
            payload: Data([0xca, 0xfe])
        ))
    }

    private static func accessibilityEnvelope(
        terminalID: UUID? = nil,
        generation: UInt64 = 1,
        contentSequence: UInt64 = 11,
        presentationSequence: UInt64 = 1
    ) -> MobileTerminalSceneEnvelope {
        let terminalID = terminalID ?? Self.terminalID
        return .accessibility(MobileTerminalSceneAccessibility(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence,
            presentationID: presentationID,
            presentationGeneration: generation,
            presentationSequence: presentationSequence,
            columns: 80,
            rows: 24,
            text: "ready"
        ))
    }

    private static func transportRequest() throws -> CmxByteTransportRequest {
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

    private func waitForInputCount(
        _ lane: TerminalSceneTestConnection,
        count: Int
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if await lane.inputs().count == count {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private actor TerminalSceneTestConnection: MobileTerminalSceneConnection {
    private var pendingEnvelopes: [MobileTerminalSceneEnvelope]
    private let waitsAfterEnvelopes: Bool
    private let closeUnblocksReceive: Bool
    private var waiter: CheckedContinuation<MobileTerminalSceneEnvelope?, Never>?
    private var sentInputs: [Data] = []
    private var receives = 0
    private var closes = 0
    private var closed = false

    init(
        envelopes: [MobileTerminalSceneEnvelope],
        waitsAfterEnvelopes: Bool,
        closeUnblocksReceive: Bool = true
    ) {
        pendingEnvelopes = envelopes
        self.waitsAfterEnvelopes = waitsAfterEnvelopes
        self.closeUnblocksReceive = closeUnblocksReceive
    }

    func receiveEnvelope() async -> MobileTerminalSceneEnvelope? {
        receives += 1
        if !pendingEnvelopes.isEmpty {
            return pendingEnvelopes.removeFirst()
        }
        guard waitsAfterEnvelopes else { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func sendInput(_ input: Data) {
        sentInputs.append(input)
    }

    func close() {
        guard !closed else { return }
        closed = true
        closes += 1
        if closeUnblocksReceive {
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    func enqueue(_ envelope: MobileTerminalSceneEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            pendingEnvelopes.append(envelope)
        }
    }

    func inputs() -> [Data] { sentInputs }
    func receiveCount() -> Int { receives }
    func closeCount() -> Int { closes }
}

private actor TerminalSceneTestProvider {
    enum ProviderError: Error { case exhausted }

    private var lanes: [TerminalSceneTestConnection]

    init(lanes: [TerminalSceneTestConnection]) {
        self.lanes = lanes
    }

    func callAsFunction(
        _: CmxByteTransportRequest,
        _: MobileTerminalSceneRequest
    ) throws -> any MobileTerminalSceneConnection {
        guard !lanes.isEmpty else { throw ProviderError.exhausted }
        return lanes.removeFirst()
    }
}

private actor TerminalSceneConsumerGate {
    private let presentedContentSequences: Set<UInt64>
    private var startedCount = 0
    private var startedContinuation: AsyncStream<Int>.Continuation?
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(presentedContentSequences: Set<UInt64> = [11]) {
        self.presentedContentSequences = presentedContentSequences
    }

    func startedStream() -> AsyncStream<Int> {
        AsyncStream { startedContinuation = $0 }
    }

    func consume(_ envelope: MobileTerminalSceneEnvelope) async -> Bool {
        startedCount += 1
        startedContinuation?.yield(startedCount)
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        if case let .accessibility(accessibility) = envelope {
            return presentedContentSequences.contains(accessibility.contentSequence)
        }
        return false
    }

    func releaseOne() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            permits += 1
        }
    }
}

private actor TerminalSceneEnvelopeRecorder {
    private var envelopes: [MobileTerminalSceneEnvelope] = []
    private var continuation: AsyncStream<Int>.Continuation?

    func countStream() -> AsyncStream<Int> {
        AsyncStream { continuation = $0 }
    }

    func append(_ envelope: MobileTerminalSceneEnvelope) -> Bool {
        envelopes.append(envelope)
        continuation?.yield(envelopes.count)
        if case .accessibility = envelope { return true }
        return false
    }

    func terminalIDs() -> [UUID] {
        envelopes.map {
            switch $0 {
            case .configuration(let configuration):
                configuration.terminalID
            case .scene(let scene):
                scene.terminalID
            case .accessibility(let accessibility):
                accessibility.terminalID
            }
        }
    }
}

private actor TerminalSceneTerminationRecorder {
    struct Value: Sendable {
        let token: UUID
        let termination: MobileTerminalSceneTermination
    }

    private var continuation: AsyncStream<Value>.Continuation?

    func stream() -> AsyncStream<Value> {
        AsyncStream { continuation = $0 }
    }

    func append(token: UUID, termination: MobileTerminalSceneTermination) {
        continuation?.yield(Value(token: token, termination: termination))
    }
}
