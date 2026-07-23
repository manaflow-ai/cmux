import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct TerminalRawInputOrderingTests {
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
        _ = await waitForTerminalInputCount(4, router: router)
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

    private func waitForTerminalInputCount(
        _ expectedCount: Int,
        router: RoutingHostRouter
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
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
}
