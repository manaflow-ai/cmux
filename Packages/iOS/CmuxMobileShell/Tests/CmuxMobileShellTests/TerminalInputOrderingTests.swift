import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct TerminalInputOrderingTests {
    @Test func fastRawInputDoesNotPassEarlierUnacknowledgedInput() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let terminalID = RoutingHostRouter.terminalA
        store.selectTerminal(.init(rawValue: terminalID))

        await router.setHoldFirstTerminalInput(true)
        let first = Task {
            await store.submitTerminalRawInput(Data("a".utf8), surfaceID: terminalID)
        }
        await router.awaitFirstTerminalInputReached()

        let second = Task {
            await store.submitTerminalRawInput(Data("b".utf8), surfaceID: terminalID)
        }

        for _ in 0..<50 {
            await Task.yield()
        }

        let beforeRelease = await router.recordedInputs()
        #expect(
            beforeRelease.isEmpty,
            "later terminal input must stay queued while an earlier terminal.input RPC is unacknowledged"
        )

        await router.releaseFirstTerminalInput()
        await first.value
        await second.value
        await router.awaitRecordedInputCount(2)

        let inputs = await router.recordedInputs()
        #expect(inputs.map(\.surfaceID) == [terminalID, terminalID])
        #expect(inputs.map(\.text) == ["a", "b"])
    }
}
