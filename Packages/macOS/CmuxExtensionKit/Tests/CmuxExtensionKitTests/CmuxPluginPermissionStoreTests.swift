import Foundation
import Testing
@testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    @Test
    func permissionStorePersistsApprovedGrantAcrossInstances() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("plugin-grants.json")
        let plugin = Self.permissionTestPlugin(directoryURL: root)

        let firstStore = CmuxPluginPermissionStore(storageURL: storageURL)
        try await firstStore.approveAll(for: plugin)

        let reloadedStore = CmuxPluginPermissionStore(storageURL: storageURL)
        let grant = await reloadedStore.grant(for: plugin)
        #expect(grant.approved)
        #expect(grant.enabled)
        #expect(grant.events == [.workspaceCreated])
        #expect(grant.actions == ["run"])
    }

    @Test(arguments: [
        Data(#"{"schemaVersion":1,"grants":}"#.utf8),
        Data(#"{"schemaVersion":999,"grants":{}}"#.utf8),
    ])
    func permissionStorePreservesUnusableGrantFiles(originalData: Data) async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("plugin-grants.json")
        try originalData.write(to: storageURL)
        let store = CmuxPluginPermissionStore(storageURL: storageURL)
        let plugin = Self.permissionTestPlugin(directoryURL: root)

        #expect(await store.permissions(for: plugin) == .none)
        do {
            try await store.approveAll(for: plugin)
            Issue.record("An unusable grant file must block permission writes")
        } catch {}
        #expect(try Data(contentsOf: storageURL) == originalData)
    }

    private static func permissionTestPlugin(directoryURL: URL) -> CmuxLoadedPlugin {
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.permissions",
            displayName: "Permissions",
            pluginScopes: [.eventHooks, .paletteActions],
            eventSubscriptions: [.workspaceCreated],
            actions: [CmuxExtensionAction(id: "run", title: "Run")],
            entrypoint: "bin/plugin"
        )
        return CmuxLoadedPlugin(
            manifest: manifest,
            directoryURL: directoryURL,
            entrypointURL: directoryURL.appendingPathComponent("plugin"),
            manifestFingerprint: "fingerprint"
        )
    }
}
