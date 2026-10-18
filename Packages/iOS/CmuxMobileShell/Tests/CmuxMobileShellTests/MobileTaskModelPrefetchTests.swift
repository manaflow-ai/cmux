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
        let composerStart = MobileTaskModelPrefetchStartProbe()
        let composer = Task {
            await composerStart.signal()
            return await store.refreshTaskModels(
                provider: .claude, macDeviceID: "test-mac", instanceTag: nil, maximumCacheAge: 300
            )
        }
        await composerStart.wait()
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

    @Test func failedCatalogIsSharedAcrossThePrefetchWave() async throws {
        let probe = MobileTaskModelPrefetchCatalogProbe(data: Data("{}".utf8))
        let catalog = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in await probe.load() }
        )
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(), hostCapabilities: [], taskModelCatalogClient: catalog
        )

        await store.prefetchTaskModels(for: [
            .init(macDeviceID: "offline-a", instanceTag: nil, connectionIdentity: nil),
            .init(macDeviceID: "offline-b", instanceTag: nil, connectionIdentity: nil),
            .init(macDeviceID: "offline-c", instanceTag: nil, connectionIdentity: nil),
        ])

        #expect(await probe.requestCount == 1)
    }

    @Test func canceledCatalogConsumerReturnsBeforeSharedCatalogFinishes() async throws {
        let probe = MobileTaskModelPrefetchCatalogProbe(data: Data(
            #"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]}}}"#.utf8
        ))
        await probe.setHold(true)
        let client = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in await probe.load() }
        )
        let catalog = MobileTaskModelPrefetchCatalog(client: client, startedAt: Date())
        await probe.waitUntilStarted()

        let consumer = Task {
            await catalog.result(for: .claude)
        }
        let cancellationStartedAt = ContinuousClock.now
        consumer.cancel()
        #expect(await consumer.value == nil)
        #expect(ContinuousClock.now - cancellationStartedAt < .seconds(1))

        await probe.release()
        catalog.cancel()
    }

    @Test func lateCatalogConsumerReceivesTheCompletedProviderResult() async throws {
        let probe = MobileTaskModelPrefetchCatalogProbe(data: Data(
            #"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]}}}"#.utf8
        ))
        let client = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://catalog.example.test/models")!,
            loader: { _ in await probe.load() }
        )
        let catalog = MobileTaskModelPrefetchCatalog(client: client, startedAt: Date())

        let first = await catalog.result(for: .claude)
        let late = await catalog.result(for: .claude)

        #expect(first?.models.map(\.id) == ["backend-claude"])
        #expect(late == first)
        #expect(await probe.requestCount == 1)
        catalog.cancel()
    }

    @Test func concurrentCatalogConsumersAllReceiveTheSharedResult() async {
        for _ in 0..<20 {
            let probe = MobileTaskModelPrefetchCatalogProbe(data: Data(
                #"{"schemaVersion":1,"providers":{"claude":{"models":[{"id":"backend-claude","label":"Backend Claude"}]}}}"#.utf8
            ))
            await probe.setHold(true)
            let client = MobileTaskModelCatalogClient(
                endpoint: URL(string: "https://catalog.example.test/models")!,
                loader: { _ in await probe.load() }
            )
            let catalog = MobileTaskModelPrefetchCatalog(client: client, startedAt: Date())
            let consumerStarts = AsyncStream<Void>.makeStream()
            let consumers = Task {
                await withTaskGroup(of: MobileTaskModelListResult?.self) { group in
                    for _ in 0..<32 {
                        group.addTask {
                            consumerStarts.continuation.yield(())
                            return await catalog.result(for: .claude)
                        }
                    }
                    for await result in group {
                        #expect(result?.models.map(\.id) == ["backend-claude"])
                    }
                }
            }
            await probe.waitUntilStarted()
            var started = 0
            for await _ in consumerStarts.stream {
                started += 1
                if started == 32 { break }
            }
            consumerStarts.continuation.finish()
            await probe.release()
            await consumers.value
            #expect(await probe.requestCount == 1)
            catalog.cancel()
        }
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
