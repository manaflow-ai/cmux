import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
struct MobileTaskModelPrefetchTests {
    @Test func warmsEveryProviderAndReusesTheCatalogWhenComposerOpens() async throws {
        let router = RoutingHostRouter()
        for provider in MobileTaskAgentProvider.allCases {
            await router.setTaskModels(
                [.init(id: "\(provider.rawValue)-model", displayName: provider.rawValue)],
                provider: provider
            )
        }
        let store = try await makeRoutingConnectedStore(router: router, hostCapabilities: [])
        let identity = try #require(store.taskModelConnectionIdentity(macDeviceID: "test-mac", instanceTag: nil))
        let target = MobileTaskModelPrefetchTarget(
            macDeviceID: "test-mac", instanceTag: nil, connectionIdentity: identity
        )
        await store.prefetchTaskModels(for: [target])
        #expect(Set(await router.recordedTaskModelListProviders()) == Set(MobileTaskAgentProvider.allCases.map(\.rawValue)))
        for provider in MobileTaskAgentProvider.allCases {
            #expect(store.discoveredTaskModels(provider: provider, macDeviceID: "test-mac", instanceTag: nil)?.first?.id == "\(provider.rawValue)-model")
            let outcome = await store.refreshTaskModels(
                provider: provider, macDeviceID: "test-mac", instanceTag: nil,
                maximumCacheAge: 300
            )
            #expect(outcome == .succeeded)
        }
        await store.prefetchTaskModels(for: [target])
        #expect(await router.recordedTaskModelListProviders().count == MobileTaskAgentProvider.allCases.count)
    }

    @Test func obsoleteConnectionDoesNotPrefetchIntoReplacement() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router, hostCapabilities: [])
        await store.prefetchTaskModels(for: [
            .init(macDeviceID: "test-mac", instanceTag: nil, connectionIdentity: "old-connection"),
            .init(macDeviceID: "offline", instanceTag: nil, connectionIdentity: "missing"),
        ])
        #expect(await router.recordedTaskModelListProviders().isEmpty)
    }
}
