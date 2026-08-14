import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    @Test
    func sidebarManifestEncodingKeepsLegacyRequiredArrays() throws {
        let manifest = CmuxExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Sidebar"
        )

        let data = try JSONEncoder().encode(manifest)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["readScopes"] as? [String] == [])
        #expect(object["actionScopes"] as? [String] == [])
        #expect(object["kind"] == nil)
    }

    @Test
    func pluginManifestRejectsControlCharactersInUserVisibleDeclarations() {
        let manifests = [
            CmuxExtensionManifest.plugin(
                id: "dev.example.display-controls",
                displayName: "Unsafe\nPlugin",
                entrypoint: "bin/plugin"
            ),
            CmuxExtensionManifest.plugin(
                id: "dev.example.action-controls",
                displayName: "Plugin",
                pluginScopes: [.paletteActions],
                actions: [CmuxExtensionAction(id: "run", title: "Run\tNow")],
                entrypoint: "bin/plugin"
            ),
            CmuxExtensionManifest.plugin(
                id: "dev.example.directional-controls",
                displayName: "Unsafe\u{202E}Plugin",
                entrypoint: "bin/plugin"
            ),
        ]

        for manifest in manifests {
            #expect(throws: CmuxExtensionValidationError.self) {
                try validatePluginManifest(manifest)
            }
        }
    }

    @Test
    func protocolValuesRoundTripAndPolicyFailsClosed() throws {
        let envelope = CmuxPluginEventEnvelope(
            bootID: "boot",
            sequence: 4,
            id: "boot-4",
            name: "workspace.created",
            category: "workspace",
            source: "test",
            occurredAt: "2026-01-01T00:00:00Z",
            payload: ["count": .number(2), "ok": .bool(true)]
        )
        #expect(try JSONDecoder().decode(
            CmuxPluginEventEnvelope.self,
            from: JSONEncoder().encode(envelope)
        ) == envelope)

        let request = CmuxPluginSubscriptionRequest(
            pluginID: "dev.example.plugin",
            token: "secret",
            afterSequence: 3,
            eventNames: ["workspace.created"]
        )
        #expect(try JSONDecoder().decode(
            CmuxPluginSubscriptionRequest.self,
            from: JSONEncoder().encode(request)
        ) == request)
        #expect(CmuxExtensionJSONValue(foundationValue: Double.nan) == .null)
        #expect(CmuxExtensionJSONValue(foundationValue: Double.infinity) == .null)
        let foundationJSON = try #require(JSONSerialization.jsonObject(
            with: Data(#"{"number":1,"boolean":true}"#.utf8)
        ) as? [String: Any])
        #expect(CmuxExtensionJSONValue(
            foundationValue: try #require(foundationJSON["number"])
        ) == .number(1))
        #expect(CmuxExtensionJSONValue(
            foundationValue: try #require(foundationJSON["boolean"])
        ) == .bool(true))

        let policy = CmuxPluginSubscriptionPolicy(
            pluginID: "dev.example.plugin",
            permissions: CmuxPluginPermissions(
                enabled: true,
                pluginScopes: [.eventHooks, .paletteActions],
                events: [.workspaceCreated],
                actions: ["run"]
            )
        )
        #expect(policy.allowsEvent(name: "workspace.created"))
        #expect(policy.allowsEvent(name: "Workspace.Created"))
        #expect(policy.allowsEvent(name: "notification.posted") == false)
        #expect(policy.allowsEvent(name: CmuxPluginActionInvocation.eventName))
        #expect(!policy.allowsEvent(name: "workspace.closed"))
        #expect(policy.allowsAction(id: "run"))
        #expect(!policy.allowsAction(id: "delete"))
    }

    @Test
    func registryIssuesTokensAndAuthorizesOnlyGrantedEventsAndActions() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.registry",
            displayName: "Registry",
            pluginScopes: [.eventHooks, .paletteActions],
            eventSubscriptions: [.workspaceCreated],
            actions: [CmuxExtensionAction(id: "run", title: "Run")],
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let registry = CmuxPluginRegistry(
            loader: CmuxPluginDirectoryLoader(directoryURL: root),
            permissionStore: CmuxPluginPermissionStore(storageURL: nil)
        )
        _ = await registry.reload()
        _ = try await registry.approveAll(pluginID: manifest.id)
        let token = try await registry.sessionToken(pluginID: manifest.id)

        #expect(try await registry.authorizeSubscription(
            pluginID: manifest.id,
            token: token,
            requestedNames: ["workspace.created"]
        ) == ["workspace.created"])
        #expect(try await registry.authorizeSubscription(
            pluginID: manifest.id,
            token: token,
            requestedNames: ["Workspace.Created"]
        ) == ["workspace.created"])
        #expect(try await registry.authorizeSubscription(
            pluginID: manifest.id,
            token: token,
            requestedNames: [CmuxPluginActionInvocation.eventName]
        ) == [CmuxPluginActionInvocation.eventName])
        do {
            _ = try await registry.authorizeSubscription(
                pluginID: manifest.id,
                token: token,
                requestedNames: ["workspace.closed"]
            )
            Issue.record("An ungranted event should be rejected")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .eventNotGranted("workspace.closed"))
        }
        try await registry.authorizeAction(pluginID: manifest.id, actionID: "run")
        #expect(await registry.action(
            forNamespacedID: "plugin.dev.example.registry.run"
        )?.action.id == "run")
        do {
            try await registry.authorizeAction(pluginID: manifest.id, actionID: "delete")
            Issue.record("An undeclared action should be rejected")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .actionNotGranted("delete"))
        }
    }

    @Test
    func registryResolvesReverseDNSActionNamespacesWithoutAmbiguousSplitting() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.registry",
            displayName: "Registry",
            pluginScopes: [.paletteActions],
            actions: [CmuxExtensionAction(id: "run.now", title: "Run")],
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let registry = CmuxPluginRegistry(
            loader: CmuxPluginDirectoryLoader(directoryURL: root),
            permissionStore: CmuxPluginPermissionStore(storageURL: nil)
        )
        _ = await registry.reload()
        _ = try await registry.approveAll(pluginID: manifest.id)

        #expect(await registry.action(
            forNamespacedID: "plugin.dev.example.registry.run.now"
        )?.action.id == "run.now")
    }
}
