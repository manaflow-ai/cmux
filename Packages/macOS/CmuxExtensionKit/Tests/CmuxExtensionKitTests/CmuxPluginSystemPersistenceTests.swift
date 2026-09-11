import Foundation
import Testing
@testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    @Test
    func permissionStorePersistsApprovalAcrossStoreInstances() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.persisted-permissions",
            displayName: "Persisted Permissions",
            pluginScopes: [.eventHooks, .paletteActions],
            eventSubscriptions: [.workspaceCreated],
            actions: [CmuxExtensionAction(id: "run", title: "Run")],
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let plugin = try #require(
            (await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first
        )
        let storageURL = root.appendingPathComponent("plugin-grants.json")

        let firstStore = CmuxPluginPermissionStore(storageURL: storageURL)
        try await firstStore.approveAll(for: plugin)

        let secondStore = CmuxPluginPermissionStore(storageURL: storageURL)
        let grant = await secondStore.grant(for: plugin)
        let permissions = await secondStore.permissions(for: plugin)

        #expect(grant.approved)
        #expect(grant.enabled)
        #expect(grant.manifestFingerprint == plugin.manifestFingerprint)
        #expect(grant.events == [.workspaceCreated])
        #expect(grant.actions == ["run"])
        #expect(permissions.enabled)
        #expect(permissions.pluginScopes == [.eventHooks, .paletteActions])
        #expect(permissions.events == [.workspaceCreated])
        #expect(permissions.actions == ["run"])
    }
}
