import Foundation
import Testing
import CmuxMobileShellModel
@testable import CmuxMobileShell

@Suite("Mobile connection lifecycle ownership")
@MainActor
struct MobileConnectionLifecycleOwnershipTests {
    @Test("a persisted client gets a new interaction session per shell process")
    func persistedClientGetsNewProcessSession() async throws {
        let suiteName = "MobileConnectionLifecycleOwnershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = MobileClientIDRepository(defaults: defaults)

        let firstRouter = RoutingHostRouter()
        let first = try await makeRoutingConnectedStore(
            router: firstRouter,
            clientIDRepository: repository
        )
        let restartedRouter = RoutingHostRouter()
        let restarted = try await makeRoutingConnectedStore(
            router: restartedRouter,
            clientIDRepository: repository
        )

        await first.submitTerminalRawInput(Data("a".utf8), surfaceID: RoutingHostRouter.terminalA)
        await restarted.submitTerminalRawInput(Data("b".utf8), surfaceID: RoutingHostRouter.terminalA)
        let firstRequest = try #require(await firstRouter.recordedTerminalInteractions().first)
        let restartedRequest = try #require(await restartedRouter.recordedTerminalInteractions().first)

        #expect(first.clientID == restarted.clientID)
        #expect(firstRequest.clientID == first.clientID)
        #expect(restartedRequest.clientID == restarted.clientID)
        #expect(firstRequest.interactionSessionID != nil)
        #expect(restartedRequest.interactionSessionID != nil)
        #expect(firstRequest.interactionSessionID != restartedRequest.interactionSessionID)
    }
}
