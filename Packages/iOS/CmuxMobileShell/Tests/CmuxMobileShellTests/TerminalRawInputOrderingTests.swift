import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct TerminalRawInputOrderingTests {
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
        for _ in 0..<1_000 {
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
