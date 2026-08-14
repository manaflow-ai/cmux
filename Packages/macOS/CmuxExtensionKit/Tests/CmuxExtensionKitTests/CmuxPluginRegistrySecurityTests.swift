import Foundation
import Testing
@testable import CmuxExtensionKit

@Suite(.serialized)
struct CmuxPluginRegistrySecurityTests {
    @Test
    func approvedManifestFingerprintChangeRotatesSessionToken() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.token-rotation",
            displayName: "Token Rotation",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(manifest, to: root)

        let loader = CmuxPluginDirectoryLoader(directoryURL: root)
        let store = CmuxPluginPermissionStore(storageURL: nil)
        let registry = CmuxPluginRegistry(loader: loader, permissionStore: store)
        _ = await registry.reload()
        let firstPlugin = try #require((await loader.load()).plugins.first)

        try await store.approveAll(for: firstPlugin)
        _ = await registry.reload()
        let firstToken = try await registry.sessionToken(pluginID: manifest.id)

        var changedManifest = manifest
        changedManifest.displayName = "Token Rotation Changed"
        let manifestURL = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        try JSONEncoder().encode(changedManifest).write(to: manifestURL, options: .atomic)
        let changedPlugin = try #require((await loader.load()).plugins.first)

        try await store.setGrant(CmuxPluginGrant(
            pluginID: changedPlugin.manifest.id,
            manifestFingerprint: changedPlugin.manifestFingerprint,
            enabled: true,
            approved: true,
            pluginScopes: Set(changedPlugin.manifest.pluginScopes),
            events: Set(changedPlugin.manifest.eventSubscriptions)
        ))
        _ = await registry.reload()
        let secondToken = try await registry.sessionToken(pluginID: manifest.id)

        #expect(secondToken != firstToken)
    }
}
