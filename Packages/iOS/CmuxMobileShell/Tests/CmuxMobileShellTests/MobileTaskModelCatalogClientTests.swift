import Foundation
import Observation
import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

private actor MobileTaskModelCatalogProbe {
    private var responses: [Data?]
    private(set) var requestCount = 0

    init(responses: [Data?]) {
        self.responses = responses
    }

    func load(_ url: URL) throws -> Data {
        requestCount += 1
        guard !responses.isEmpty,
              let response = responses.removeFirst() else {
            throw URLError(.cannotLoadFromNetwork)
        }
        return response
    }
}

@Suite("Mobile task model backend catalog")
struct MobileTaskModelCatalogClientTests {
    private let endpoint = URL(string: "https://catalog.example.test/models")!

    @Test func parsesProviderModelsWithoutInventingDeviceValues() throws {
        let models = try MobileTaskModelCatalogClient.models(
            from: catalogData(
                claude: [
                    ("backend-next-999", "Backend Next 999"),
                    ("backend-next-999", "Duplicate"),
                    ("  ", "Blank"),
                ],
                codex: [("codex-backend-998", "Codex Backend 998")]
            ),
            provider: .claude
        )

        #expect(models == [
            MobileTaskAgentModel(
                id: "backend-next-999",
                displayName: "Backend Next 999"
            ),
        ])
    }

    @Test func parsesEffortsOnlyFromTheirExactModel() throws {
        let data = Data(#"{"schemaVersion":1,"providers":{"codex":{"models":[{"id":"gpt-large","label":"GPT Large","efforts":[{"value":"medium","label":"Medium","description":"Balanced"},{"value":"high","label":"High"}],"defaultEffort":"medium"},{"id":"gpt-small","label":"GPT Small","efforts":[{"value":"low","label":"Low"}],"defaultEffort":"low"}]}}}"#.utf8)

        let models = try MobileTaskModelCatalogClient.models(
            from: data,
            provider: .codex
        )

        #expect(models == [
            MobileTaskAgentModel(
                id: "gpt-large",
                displayName: "GPT Large",
                efforts: [
                    MobileTaskAgentEffort(
                        id: "medium",
                        displayName: "Medium",
                        description: "Balanced"
                    ),
                    MobileTaskAgentEffort(id: "high", displayName: "High"),
                ],
                defaultEffortID: "medium"
            ),
            MobileTaskAgentModel(
                id: "gpt-small",
                displayName: "GPT Small",
                efforts: [MobileTaskAgentEffort(id: "low", displayName: "Low")],
                defaultEffortID: "low"
            ),
        ])
    }

    @Test func resolvesProviderDefaultModelEffortsWithoutInventingAPickerModel() throws {
        let data = Data(#"{"schemaVersion":1,"providers":{"claude":{"defaultModel":"claude-default","models":[{"id":"claude-default","label":"Claude Default","efforts":[{"value":"medium","label":"Medium"},{"value":"high","label":"High"}],"defaultEffort":"medium"},{"id":"claude-other","label":"Claude Other","efforts":[{"value":"low","label":"Low"}],"defaultEffort":"low"}]}}}"#.utf8)

        let result = try MobileTaskModelCatalogClient.result(
            from: data,
            provider: .claude
        )

        #expect(result.models.map(\.id) == ["claude-default", "claude-other"])
        #expect(result.defaultModel == MobileTaskAgentModel(
            id: "claude-default",
            displayName: "Claude Default",
            efforts: [
                MobileTaskAgentEffort(id: "medium", displayName: "Medium"),
                MobileTaskAgentEffort(id: "high", displayName: "High"),
            ],
            defaultEffortID: "medium"
        ))
    }

    @Test func sameInstalledClientObservesModelsReleasedAfterFirstRefresh() async throws {
        let probe = MobileTaskModelCatalogProbe(responses: [
            catalogData(claude: [("backend-next-999", "Backend Next 999")]),
            catalogData(claude: [
                ("backend-next-999", "Backend Next 999"),
                ("backend-release-after-build", "Released After Build"),
            ]),
        ])
        let client = makeClient(probe: probe)

        let first = try await client.models(for: .claude)
        let second = try await client.models(for: .claude)

        #expect(first.map(\.id) == ["backend-next-999"])
        #expect(second.map(\.id) == [
            "backend-next-999",
            "backend-release-after-build",
        ])
        #expect(await probe.requestCount == 2)
    }

    @MainActor
    @Test func authoritativeHostCatalogPerformsZeroBackendRequests() async {
        let probe = MobileTaskModelCatalogProbe(responses: [
            catalogData(claude: [("backend-next-999", "Backend Next 999")]),
        ])
        let store = MobileShellComposite(
            taskModelCatalogClient: makeClient(probe: probe)
        )

        await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "mac-host",
            hostResult: MobileTaskModelListResult(
                models: [
                    MobileTaskAgentModel(
                        id: "host-next-999",
                        displayName: "Host Next 999"
                    ),
                ],
                source: .discovered
            )
        )

        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "mac-host",
            instanceTag: nil
        )?.map(\.id) == ["host-next-999"])
        #expect(store.taskModelListSource(
            provider: .claude,
            macDeviceID: "mac-host",
            instanceTag: nil
        ) == .discovered)
        #expect(await probe.requestCount == 0)
    }

    @MainActor
    @Test func safeHostProbeOverridesBackendWhenCapabilitySnapshotIsStale() async throws {
        let probe = MobileTaskModelCatalogProbe(responses: [
            catalogData(claude: [("backend-next-999", "Backend Next 999")]),
        ])
        let router = RoutingHostRouter()
        await router.setTaskModels(
            [
                MobileTaskAgentModel(
                    id: "host-next-999",
                    displayName: "Host Next 999",
                    efforts: [
                        MobileTaskAgentEffort(
                            id: "high",
                            displayName: "High",
                            description: "More reasoning"
                        ),
                    ],
                    defaultEffortID: "high"
                ),
            ],
            provider: .claude
        )
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [],
            taskModelCatalogClient: makeClient(probe: probe)
        )

        await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        )

        #expect(await router.recordedTaskModelListProviders() == ["claude"])
        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        ) == [
            MobileTaskAgentModel(
                id: "host-next-999",
                displayName: "Host Next 999",
                efforts: [
                    MobileTaskAgentEffort(
                        id: "high",
                        displayName: "High",
                        description: "More reasoning"
                    ),
                ],
                defaultEffortID: "high"
            ),
        ])
        #expect(store.taskModelListSource(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        ) == .discovered)
    }

    @MainActor
    @Test func backendAppearsWhileSlowHostDiscoveryContinuesThenHostWins() async throws {
        let probe = MobileTaskModelCatalogProbe(responses: [
            catalogData(claude: [("backend-next-999", "Backend Next 999")]),
        ])
        let router = RoutingHostRouter()
        await router.setTaskModels(
            [
                MobileTaskAgentModel(
                    id: "host-next-999",
                    displayName: "Host Next 999"
                ),
            ],
            provider: .claude
        )
        await router.setHoldTaskModelList(true)
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [],
            taskModelCatalogClient: makeClient(probe: probe)
        )
        let connectedRefresh = Task { @MainActor in
            await store.refreshTaskModels(
                provider: .claude,
                macDeviceID: "test-mac",
                instanceTag: nil
            )
        }
        await router.awaitTaskModelListReached()
        for _ in 0..<100 {
            if store.taskModelListSource(
                provider: .claude,
                macDeviceID: "test-mac",
                instanceTag: nil
            ) == .backend {
                break
            }
            await Task.yield()
        }
        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        )?.map(\.id) == ["backend-next-999"])

        await router.releaseTaskModelList()
        await connectedRefresh.value

        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        )?.map(\.id) == ["host-next-999"])
        #expect(await probe.requestCount == 1)
    }

    @MainActor
    @Test func connectionAvailabilityPublishesModelRefreshIdentity() async throws {
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            hostCapabilities: []
        )
        let secondaryRouter = RoutingHostRouter()

        try await confirmation("selected model connection becomes available") {
            didChange in
            withObservationTracking {
                #expect(store.taskModelConnectionIdentity(
                    macDeviceID: "secondary-mac",
                    instanceTag: nil
                ) == nil)
            } onChange: {
                didChange()
            }

            try installSecondaryClient(
                on: store,
                macDeviceID: "secondary-mac",
                router: secondaryRouter,
                supportedHostCapabilities: []
            )
        }

        #expect(store.taskModelConnectionIdentity(
            macDeviceID: "secondary-mac",
            instanceTag: nil
        ) != nil)
    }

    @MainActor
    @Test func focusedClientProbeDoesNotDependOnTerminalHealthState() async throws {
        let router = RoutingHostRouter()
        await router.setTaskModels(
            [
                MobileTaskAgentModel(
                    id: "host-next-999",
                    displayName: "Host Next 999"
                ),
            ],
            provider: .claude
        )
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: []
        )
        let connectionIdentity = store.taskModelConnectionIdentity(
            macDeviceID: "test-mac",
            instanceTag: nil
        )

        // Terminal stream health can enter recovery while the owned RPC
        // client remains usable. Read-only discovery should probe that exact
        // client instead of depending on the workspace mutation state flag.
        store.connectionState = .disconnected
        let result = try await store.fetchTaskModels(
            provider: .claude,
            macDeviceID: "test-mac",
            instanceTag: nil
        )

        #expect(result.models.map(\.id) == ["host-next-999"])
        #expect(connectionIdentity != nil)
        #expect(store.taskModelConnectionIdentity(
            macDeviceID: "test-mac",
            instanceTag: nil
        ) == connectionIdentity)
        #expect(await router.recordedTaskModelListProviders() == ["claude"])
    }

    @MainActor
    @Test func controlClientProbeDoesNotChangeTheFocusedMac() async throws {
        let foregroundRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: foregroundRouter,
            hostCapabilities: []
        )
        let focusedClient = store.remoteClient
        let secondaryRouter = RoutingHostRouter()
        await secondaryRouter.setTaskModels(
            [
                MobileTaskAgentModel(
                    id: "secondary-host-next-999",
                    displayName: "Secondary Host Next 999"
                ),
            ],
            provider: .claude
        )
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-mac",
            router: secondaryRouter,
            supportedHostCapabilities: []
        )
        let foregroundIdentity = store.taskModelConnectionIdentity(
            macDeviceID: "test-mac",
            instanceTag: nil
        )
        let secondaryIdentity = store.taskModelConnectionIdentity(
            macDeviceID: "secondary-mac",
            instanceTag: nil
        )

        let result = try await store.fetchTaskModels(
            provider: .claude,
            macDeviceID: "secondary-mac",
            instanceTag: nil
        )

        #expect(result.models.map(\.id) == ["secondary-host-next-999"])
        #expect(foregroundIdentity != nil)
        #expect(secondaryIdentity != nil)
        #expect(secondaryIdentity != foregroundIdentity)
        #expect(await secondaryRouter.recordedTaskModelListProviders() == ["claude"])
        #expect(await foregroundRouter.recordedTaskModelListProviders().isEmpty)
        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(store.remoteClient === focusedClient)
    }

    @MainActor
    @Test func refreshFallsBackToBackendAndPreservesLastValidCatalogOnFailure() async {
        let initialData = catalogData(
            claude: [("backend-next-999", "Backend Next 999")]
        )
        let probe = MobileTaskModelCatalogProbe(responses: [initialData, nil])
        let store = MobileShellComposite(
            taskModelCatalogClient: makeClient(probe: probe)
        )

        await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            hostResult: MobileTaskModelListResult(
                models: [
                    MobileTaskAgentModel(
                        id: "legacy-device-value",
                        displayName: "Legacy Device Value"
                    ),
                ],
                source: .fallback
            )
        )
        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            instanceTag: "stable"
        )?.map(\.id) == ["backend-next-999"])
        #expect(store.taskModelListSource(
            provider: .claude,
            macDeviceID: "mac-a",
            instanceTag: "stable"
        ) == .backend)

        await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            hostResult: nil
        )

        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            instanceTag: "stable"
        )?.map(\.id) == ["backend-next-999"])
        #expect(await probe.requestCount == 2)
    }

    @MainActor
    @Test func cachesRemainIsolatedByMacAndProvider() async {
        let probe = MobileTaskModelCatalogProbe(responses: [
            catalogData(claude: [("claude-a", "Claude A")]),
            catalogData(codex: [("codex-b", "Codex B")]),
        ])
        let store = MobileShellComposite(
            taskModelCatalogClient: makeClient(probe: probe)
        )

        await store.refreshTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            instanceTag: nil
        )
        await store.refreshTaskModels(
            provider: .codex,
            macDeviceID: "mac-b",
            instanceTag: nil
        )

        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "mac-a",
            instanceTag: nil
        )?.map(\.id) == ["claude-a"])
        #expect(store.discoveredTaskModels(
            provider: .codex,
            macDeviceID: "mac-b",
            instanceTag: nil
        )?.map(\.id) == ["codex-b"])
        #expect(store.discoveredTaskModels(
            provider: .claude,
            macDeviceID: "mac-b",
            instanceTag: nil
        ) == nil)
        #expect(store.discoveredTaskModels(
            provider: .codex,
            macDeviceID: "mac-a",
            instanceTag: nil
        ) == nil)
    }

    private func makeClient(
        probe: MobileTaskModelCatalogProbe
    ) -> MobileTaskModelCatalogClient {
        MobileTaskModelCatalogClient(endpoint: endpoint) { url in
            try await probe.load(url)
        }
    }

    private func catalogData(
        claude: [(String, String)] = [("claude-default", "Claude Default")],
        codex: [(String, String)] = [("codex-default", "Codex Default")],
        openCode: [(String, String)] = [("opencode-default", "OpenCode Default")]
    ) -> Data {
        let providers: [String: Any] = [
            "claude": providerObject(claude),
            "codex": providerObject(codex),
            "opencode": providerObject(openCode),
        ]
        return try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "updatedAt": "2026-08-09T00:00:00Z",
            "providers": providers,
        ])
    }

    private func providerObject(_ models: [(String, String)]) -> [String: Any] {
        [
            "defaultModel": models.first?.0 ?? "",
            "models": models.map { id, label in
                ["id": id, "label": label]
            },
        ]
    }
}
