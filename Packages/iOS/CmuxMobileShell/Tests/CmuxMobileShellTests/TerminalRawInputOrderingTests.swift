import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct TerminalRawInputOrderingTests {
    @MainActor
    @Test func returnKeyExposesCommandSendProgressAndSettlement() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalInput(true)
        let store = try await makeRoutingConnectedStore(router: router)

        store.sendTerminalRawInput(
            Data("\r".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        await router.awaitFirstTerminalInputReached()

        #expect(
            store.terminalSendStatus(forTerminalID: RoutingHostRouter.terminalA)
                == .sending
        )

        await router.releaseFirstTerminalInput()
        #expect(await waitForTerminalSendStatus(
            .sent,
            store: store,
            terminalID: RoutingHostRouter.terminalA
        ))
    }

    @MainActor
    @Test func rejectedReturnKeyExposesCommandSendFailure() async throws {
        let router = RoutingHostRouter()
        await router.setRejectTerminalInput(at: 0)
        let store = try await makeRoutingConnectedStore(router: router)

        store.sendTerminalRawInput(
            Data("\r".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )

        #expect(await waitForTerminalSendStatus(
            .failed,
            store: store,
            terminalID: RoutingHostRouter.terminalA
        ))
    }

    @MainActor
    @Test func secondQueuedReturnOwnsItsFailureSettlement() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalInput(true)
        await router.setRejectTerminalInput(at: 1)
        let store = try await makeRoutingConnectedStore(router: router)

        store.sendTerminalRawInput(
            Data("first\r".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        await router.awaitFirstTerminalInputReached()
        store.sendTerminalRawInput(
            Data("second\r".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )

        await router.releaseFirstTerminalInput()
        #expect(await waitForTerminalSendStatus(
            .failed,
            store: store,
            terminalID: RoutingHostRouter.terminalA
        ))
        #expect(
            await router.recordedTerminalInputs().map(\.text)
                == ["first\r", "second\r"]
        )
    }

    @MainActor
    @Test func orderedIrohFallbackPipelinesAtMostFourRequests() async throws {
        let router = RoutingHostRouter()
        await router.setHoldAllTerminalInputs(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh
        )
        let completionTracker = TerminalRawInputTaskCompletionTracker()

        for character in ["a", "z", "i", "z"] {
            await store.submitTerminalRawInput(
                Data(character.utf8),
                surfaceID: RoutingHostRouter.terminalA
            )
            await completionTracker.recordCompletion()
        }
        for character in ["!", "\n"] {
            Task { @MainActor in
                await store.submitTerminalRawInput(
                    Data(character.utf8),
                    surfaceID: RoutingHostRouter.terminalA
                )
                await completionTracker.recordCompletion()
            }
        }

        #expect(await waitForTerminalInputCount(4, router: router))
        #expect(await router.recordedTerminalInputInFlightCount() == 4)
        #expect(
            await router.recordedTerminalInputMaximumInFlightCount() == 4
        )
        #expect(
            await router.recordedTerminalInputs().map(\.text)
                == ["a", "z", "i", "z"]
        )

        await router.releaseAllTerminalInputs()
        #expect(await waitForTerminalInputCount(6, router: router))
        await router.releaseAllTerminalInputs()
        #expect(await waitForProducerCompletion(
            expectedCount: 6,
            tracker: completionTracker
        ))
        #expect(await waitForTerminalInputQuiescence(router: router))
        #expect(
            await router.recordedTerminalInputs().map(\.text).joined()
                == "aziz!\n"
        )
    }

    @MainActor
    @Test func fastTypingPreservesKeystrokeOrder() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let completionTracker = TerminalRawInputTaskCompletionTracker()
        await router.setHoldFirstTerminalInput(true)

        for character in ["a", "z", "i", "z"] {
            Task { @MainActor in
                await store.submitTerminalRawInput(
                    Data(character.utf8),
                    surfaceID: RoutingHostRouter.terminalA
                )
                await completionTracker.recordCompletion()
            }
        }

        await router.awaitFirstTerminalInputReached()
        #expect(await router.recordedTerminalInputs().count == 1)
        #expect(
            await router.recordedTerminalInputMaximumInFlightCount() == 1
        )
        await router.releaseFirstTerminalInput()
        let producersCompleted = await waitForProducerCompletion(
            expectedCount: 4,
            tracker: completionTracker
        )
        let reachedQuiescence = await waitForTerminalInputQuiescence(router: router)

        let inputs = await router.recordedTerminalInputs()
        let terminalAText = inputs
            .filter { $0.surfaceID == RoutingHostRouter.terminalA }
            .map(\.text)
            .joined()
        let maximumInFlightCount = await router.recordedTerminalInputMaximumInFlightCount()

        #expect(producersCompleted)
        #expect(reachedQuiescence)
        #expect(terminalAText == "aziz")
        #expect(maximumInFlightCount == 1)
    }

    @MainActor
    @Test func laneActivationWaitsForPipelinedRPCSettlement() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalInput(true)
        let lane = RawInputBarrierTerminalLane()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh,
            terminalLaneProvider: { _, _, _ in lane }
        )
        let outputStream = store.terminalOutputStream(
            surfaceID: RoutingHostRouter.terminalA
        )
        _ = outputStream

        await store.submitTerminalRawInput(
            Data("a".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        await router.awaitFirstTerminalInputReached()

        await lane.activate()
        #expect(await waitForLaneReadiness(
            store: store,
            surfaceID: RoutingHostRouter.terminalA
        ))

        let laneSend = Task { @MainActor in
            await store.submitTerminalRawInput(
                Data("b".utf8),
                surfaceID: RoutingHostRouter.terminalA
            )
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(await lane.inputs().isEmpty)

        await router.releaseFirstTerminalInput()
        await laneSend.value
        #expect(await waitForLaneInputCount(1, lane: lane))
        #expect(await lane.inputs() == ["b"])
        await lane.close()
    }

    @MainActor
    @Test func pooledMacSwitchClearsPreviousInputPipeline() async throws {
        let previousRouter = RoutingHostRouter()
        await previousRouter.setHoldAllTerminalInputs(true)
        let store = try await makeRoutingConnectedStore(
            router: previousRouter,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh
        )
        let previousClient = try #require(store.remoteClient)

        for character in ["a", "z", "i", "z"] {
            await store.submitTerminalRawInput(
                Data(character.utf8),
                surfaceID: RoutingHostRouter.terminalA
            )
        }
        #expect(await waitForTerminalInputCount(
            4,
            router: previousRouter
        ))

        let nextRouter = RoutingHostRouter()
        try installSecondaryClient(
            on: store,
            macDeviceID: "next-mac",
            router: nextRouter
        )
        let nextSubscription = try #require(
            store.secondaryMacSubscriptions["next-mac".pairingKey]
        )
        nextSubscription.detachKeepingClient()
        store.secondaryMacSubscriptions["next-mac".pairingKey] = nil
        store.adoptPooledRemoteClient(nextSubscription.client)

        await store.submitTerminalRawInput(
            Data("!".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )

        #expect(await waitForTerminalInputCount(
            1,
            router: nextRouter
        ))
        #expect(
            await nextRouter.recordedTerminalInputs().map(\.text)
                == ["!"]
        )
        await previousRouter.releaseAllTerminalInputs()
        await previousClient.disconnect()
        await nextSubscription.client.disconnect()
    }

    @MainActor
    @Test func pipelinedFailureUsesOperationalErrorPath() async throws {
        let router = RoutingHostRouter()
        await router.setRejectTerminalInput(at: 0)
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh
        )

        await store.submitTerminalRawInput(
            Data("x".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )

        #expect(await waitForOperationalError(store: store))
        #expect(store.connectionError != nil)
    }

    @MainActor
    @Test func heldSurfaceDoesNotBlockAnotherSurfacesSettlementOrLane() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstTerminalInput(true)
        let laneA = RawInputBarrierTerminalLane()
        let laneB = RawInputBarrierTerminalLane()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh,
            terminalLaneProvider: { _, surfaceID, _ in
                surfaceID == RoutingHostRouter.terminalB ? laneB : laneA
            }
        )
        let outputStreamA = store.terminalOutputStream(
            surfaceID: RoutingHostRouter.terminalA
        )
        let outputStreamB = store.terminalOutputStream(
            surfaceID: RoutingHostRouter.terminalB
        )
        // Discarding a stream unregisters its sink and stops the lane.
        defer { withExtendedLifetime((outputStreamA, outputStreamB)) {} }

        // Surface A's request is held open by the host.
        await store.submitTerminalRawInput(
            Data("a".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        await router.awaitFirstTerminalInputReached()

        // Surface B settles independently and its lane comes up.
        await store.submitTerminalRawInput(
            Data("b".utf8),
            surfaceID: RoutingHostRouter.terminalB
        )
        await laneB.activate()
        #expect(await waitForLaneReadiness(
            store: store,
            surfaceID: RoutingHostRouter.terminalB
        ))

        // B's lane transition must not wait for A's held request: its own
        // settlements are the only barrier that applies.
        await store.submitTerminalRawInput(
            Data("c".utf8),
            surfaceID: RoutingHostRouter.terminalB
        )
        #expect(await waitForLaneInputCount(1, lane: laneB))
        #expect(await laneB.inputs() == ["c"])
        #expect(await laneA.inputs().isEmpty)

        await router.releaseFirstTerminalInput()
        await laneB.close()
        await laneA.close()
    }

    @MainActor
    @Test func ambiguousPipelinedFailureKeepsSurfaceOffTheLane() async throws {
        let router = RoutingHostRouter()
        await router.setHoldAllTerminalInputs(true)
        let lane = RawInputBarrierTerminalLane()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh,
            terminalLaneProvider: { _, _, _ in lane },
            rpcRequestTimeoutNanoseconds: 1_000_000_000
        )
        let outputStream = store.terminalOutputStream(
            surfaceID: RoutingHostRouter.terminalA
        )
        _ = outputStream

        await store.submitTerminalRawInput(
            Data("a".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        #expect(await waitForTerminalInputCount(
            1,
            router: router,
            deadline: .seconds(5)
        ))
        // Let the held request time out client-side: an ambiguous failure,
        // because the host may still apply the input late.
        #expect(await waitForConnectionError(store: store))

        await lane.activate()
        #expect(await waitForLaneReadiness(
            store: store,
            surfaceID: RoutingHostRouter.terminalA
        ))

        await store.submitTerminalRawInput(
            Data("b".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        // The ready lane must be refused after an ambiguous failure; the
        // chunk stays on the ordered RPC path where a late-applied "a"
        // cannot be overtaken.
        #expect(await waitForTerminalInputCount(
            2,
            router: router,
            deadline: .seconds(5)
        ))
        #expect(await lane.inputs().isEmpty)
        await router.releaseAllTerminalInputs()
        await lane.close()
    }

    @MainActor
    private func waitForConnectionError(
        store: MobileShellComposite
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if store.connectionError != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    @Test func staleGenerationPipelinedFailureIsIgnored() async throws {
        let router = RoutingHostRouter()
        await router.setHoldAllTerminalInputs(true)
        await router.setRejectTerminalInput(at: 0)
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [
                MobileShellComposite.terminalInputOrderedCapability,
            ],
            routeKind: .iroh
        )

        await store.submitTerminalRawInput(
            Data("x".utf8),
            surfaceID: RoutingHostRouter.terminalA
        )
        #expect(await waitForTerminalInputCount(1, router: router))
        store.connectionGeneration = UUID()
        await router.releaseAllTerminalInputs()
        #expect(await waitForTerminalInputQuiescence(router: router))
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(store.connectionError == nil)
        #expect(store.connectionState == .connected)
    }

    private func waitForTerminalInputCount(
        _ expectedCount: Int,
        router: RoutingHostRouter,
        deadline deadlineDuration: Duration = .milliseconds(500)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: deadlineDuration)
        while clock.now < deadline {
            if await router.recordedTerminalInputs().count >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForTerminalInputQuiescence(router: RoutingHostRouter) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        var stableSince = clock.now
        var lastArrivalCount = -1
        while clock.now < deadline {
            let arrivalCount = await router.recordedTerminalInputs().count
            let inFlightCount = await router.recordedTerminalInputInFlightCount()
            if arrivalCount != lastArrivalCount || inFlightCount != 0 {
                lastArrivalCount = arrivalCount
                stableSince = clock.now
            } else if stableSince.duration(to: clock.now) >= .milliseconds(20) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForProducerCompletion(
        expectedCount: Int,
        tracker: TerminalRawInputTaskCompletionTracker
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await tracker.recordedCompletionCount() >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForLaneReadiness(
        store: MobileShellComposite,
        surfaceID: String
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.terminalLaneOutputReadySurfaceIDs.contains(surfaceID) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForLaneInputCount(
        _ count: Int,
        lane: RawInputBarrierTerminalLane
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await lane.inputs().count >= count {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForOperationalError(
        store: MobileShellComposite
    ) async -> Bool {
        for _ in 0..<1_000 {
            if store.connectionError != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private func waitForTerminalSendStatus(
    _ expected: MobileTerminalSendStatus,
    store: MobileShellComposite,
    terminalID: String
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if store.terminalSendStatus(forTerminalID: terminalID) == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

private actor RawInputBarrierTerminalLane: MobileTerminalLaneConnection {
    private var pendingFrames: [MobileTerminalLaneOutputFrame] = []
    private var receiveContinuation:
        CheckedContinuation<MobileTerminalLaneOutputFrame?, Never>?
    private var sentInputs: [String] = []
    private var isClosed = false

    func receiveOutput() async -> MobileTerminalLaneOutputFrame? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed { return nil }
        return await withCheckedContinuation {
            receiveContinuation = $0
        }
    }

    func sendInput(_ input: String) {
        sentInputs.append(input)
    }

    func close() {
        isClosed = true
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }

    func activate() {
        let frame = MobileTerminalLaneOutputFrame(
            kind: .replay,
            retainedBaseSequence: 0,
            sequence: 0,
            currentSequence: 0,
            bytes: Data()
        )
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }

    func inputs() -> [String] { sentInputs }
}
