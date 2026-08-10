import Foundation
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
