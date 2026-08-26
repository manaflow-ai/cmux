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

