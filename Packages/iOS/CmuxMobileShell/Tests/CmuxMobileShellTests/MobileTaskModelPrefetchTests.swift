import Foundation
import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
struct MobileTaskModelPrefetchTests {
    @Test func sharesInFlightDiscoveryAndReusesTheWarmHostCatalog() async throws {
        let router = RoutingHostRouter()
        await router.setTaskModels(
            [.init(id: "host-model", displayName: "Host Model")], provider: .claude
        )
        await router.setHoldTaskModelList(true)
        let catalog = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in throw CancellationError() }
        )
        let store = try await makeRoutingConnectedStore(
            router: router, hostCapabilities: [], taskModelCatalogClient: catalog
        )
        let prefetch = Task {
            await store.refreshTaskModels(provider: .claude, macDeviceID: "test-mac", instanceTag: nil)
        }
        await router.awaitTaskModelListReached()
        var composerStarted = false
        let composer = Task {
            composerStarted = true
            return await store.refreshTaskModels(
                provider: .claude, macDeviceID: "test-mac", instanceTag: nil, maximumCacheAge: 300
            )
        }
        let composerStartDeadline = ContinuousClock.now + .seconds(1)
        while !composerStarted && ContinuousClock.now < composerStartDeadline {
            await Task.yield()
        }
        #expect(composerStarted)
        prefetch.cancel()
        #expect(await prefetch.value == .stopped(.cancelled))
        await router.setHoldTaskModelList(false)
        await router.releaseTaskModelList()
        #expect(await composer.value == .succeeded)
        #expect(await store.refreshTaskModels(
            provider: .claude, macDeviceID: "test-mac", instanceTag: nil, maximumCacheAge: 300
        ) == .succeeded)
        #expect(await router.recordedTaskModelListProviders() == ["claude"])
        #expect(store.discoveredTaskModels(
            provider: .claude, macDeviceID: "test-mac", instanceTag: nil
        )?.map(\.id) == ["host-model"])
    }

    @Test func warmsEveryProviderBeforeTheComposerOpens() async throws {
        let router = RoutingHostRouter()
        let catalog = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in
                Data(#"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]},"codex":{"models":[{"id":"backend-codex","label":"Backend Codex"}]},"opencode":{"models":[{"id":"backend-opencode","label":"Backend OpenCode"}]}}}"#.utf8)
            }
        )
        let store = try await makeRoutingConnectedStore(
            router: router, hostCapabilities: [], taskModelCatalogClient: catalog
        )
        let target = MobileTaskModelPrefetchTarget(
            macDeviceID: "test-mac", instanceTag: nil,
            connectionIdentity: try #require(store.taskModelConnectionIdentity(
                macDeviceID: "test-mac", instanceTag: nil
            ))
        )
        await store.prefetchTaskModels(for: [target])
        for provider in MobileTaskAgentProvider.allCases {
            #expect(
                store.discoveredTaskModels(
                    provider: provider, macDeviceID: "test-mac", instanceTag: nil
                )?.first?.id == "backend-\(provider.rawValue)"
            )
        }
    }

    @Test func targetChangesKeepUnchangedMacPrefetchAlive() async throws {
        let probe = MobileTaskModelPrefetchCatalogProbe(data: Data(
            #"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]},"codex":{"models":[{"id":"backend-codex","label":"Backend Codex"}]},"opencode":{"models":[{"id":"backend-opencode","label":"Backend OpenCode"}]}}}"#.utf8
        ))
        await probe.setHold(true)
        let catalog = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in await probe.load() }
        )
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(), hostCapabilities: [], taskModelCatalogClient: catalog
        )
        let target = MobileTaskModelPrefetchTarget(
            macDeviceID: "unchanged-mac", instanceTag: nil
        )
        let prefetch = Task {
            await store.prefetchTaskModels(for: [target, .init(
                macDeviceID: "removed-mac", instanceTag: nil
            )])
        }
        await probe.waitUntilStarted()
        store.updateTaskModelPrefetchTargets([target])
        await probe.release()
        await prefetch.value
        #expect(store.discoveredTaskModels(
            provider: .claude, macDeviceID: "unchanged-mac", instanceTag: nil
        )?.map(\.id) == ["backend-claude"])
    }

    @Test func warmsAnOfflineMacFromTheBackendCatalog() async throws {
        let probe = MobileTaskModelPrefetchCatalogProbe(data: Data(
            #"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]},"codex":{"models":[{"id":"backend-codex","label":"Backend Codex"}]},"opencode":{"models":[{"id":"backend-opencode","label":"Backend OpenCode"}]}}}"#.utf8
        ))
        let catalog = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in await probe.load() }
        )
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(), hostCapabilities: [], taskModelCatalogClient: catalog
        )
        let target = MobileTaskModelPrefetchTarget(
            macDeviceID: "offline-mac", instanceTag: nil, connectionIdentity: nil
        )
        await store.prefetchTaskModels(for: [target, .init(
            macDeviceID: "other-offline-mac", instanceTag: "nightly"
        )])
        #expect(
            store.discoveredTaskModels(
                provider: .claude, macDeviceID: "offline-mac", instanceTag: nil
            )?.first?.id == "backend-claude"
        )
        #expect(await probe.requestCount == 1)
        #expect(await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "offline-mac",
            instanceTag: nil,
            maximumCacheAge: 300
        ) == .succeeded)
        #expect(await probe.requestCount == 1)
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
