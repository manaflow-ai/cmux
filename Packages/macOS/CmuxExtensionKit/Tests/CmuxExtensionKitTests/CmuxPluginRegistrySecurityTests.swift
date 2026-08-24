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

    @Test
    func approvedEntrypointReplacementInvalidatesGrant() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.entrypoint-rotation",
            displayName: "Entrypoint Rotation",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!/bin/sh\nprintf first\n"
        )

        let loader = CmuxPluginDirectoryLoader(directoryURL: root)
        let store = CmuxPluginPermissionStore(storageURL: nil)
        let registry = CmuxPluginRegistry(loader: loader, permissionStore: store)
        _ = await registry.reload()
        let originalPlugin = try #require((await loader.load()).plugins.first)

        try await store.approveAll(for: originalPlugin)
        _ = await registry.reload()
        _ = try await registry.sessionToken(pluginID: manifest.id)

        let entrypointURL = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.entrypoint ?? "bin/plugin", isDirectory: false)
        try Data("#!/bin/sh\nprintf replacement\n".utf8)
            .write(to: entrypointURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entrypointURL.path
        )

        let replacementPlugin = try #require((await loader.load()).plugins.first)
        #expect(replacementPlugin.manifestFingerprint != originalPlugin.manifestFingerprint)

        _ = await registry.reload()
        let descriptor = try #require((await registry.snapshot()).plugins.first)
        #expect(!descriptor.isApproved)
        #expect(descriptor.permissions == .none)
        do {
            _ = try await registry.sessionToken(pluginID: manifest.id)
            Issue.record("Replacing an approved entrypoint must invalidate its grant")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .disabled)
        } catch {
            Issue.record("Unexpected authorization error: \(error)")
        }
    }

    @Test
    func approvedSiblingReplacementInvalidatesGrant() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.sibling-rotation",
            displayName: "Sibling Rotation",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(manifest, to: root)
        let siblingURL = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent("lib/helper", isDirectory: false)
        try FileManager.default.createDirectory(
            at: siblingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper-v1".utf8).write(to: siblingURL)

        let loader = CmuxPluginDirectoryLoader(directoryURL: root)
        let store = CmuxPluginPermissionStore(storageURL: nil)
        let registry = CmuxPluginRegistry(loader: loader, permissionStore: store)
        _ = await registry.reload()
        let originalPlugin = try #require((await loader.load()).plugins.first)
        try await store.approveAll(for: originalPlugin)
        _ = await registry.reload()
        _ = try await registry.sessionToken(pluginID: manifest.id)

        try Data("helper-v2".utf8).write(to: siblingURL, options: .atomic)
        let replacementPlugin = try #require((await loader.load()).plugins.first)
        #expect(replacementPlugin.manifestFingerprint != originalPlugin.manifestFingerprint)

        _ = await registry.reload()
        #expect((await registry.snapshot()).plugins.first?.permissions == .none)
        do {
            _ = try await registry.sessionToken(pluginID: manifest.id)
            Issue.record("Replacing a plugin sibling file must invalidate its grant")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .disabled)
        } catch {
            Issue.record("Unexpected authorization error: \(error)")
        }
    }

    @Test
    func executionSnapshotRemainsStableAfterSourceMutation() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let snapshotRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: snapshotRoot)
        }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.snapshot",
            displayName: "Snapshot",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!/bin/sh\nprintf original\n"
        )
        let loader = CmuxPluginDirectoryLoader(directoryURL: root)
        let plugin = try #require((await loader.load()).plugins.first)
        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: snapshotRoot)
        let snapshot = try await snapshotter.makeSnapshot(for: plugin)

        let sourceEntrypoint = root
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent("bin/plugin", isDirectory: false)
        try Data("#!/bin/sh\nprintf replacement\n".utf8)
            .write(to: sourceEntrypoint, options: .atomic)

        let copiedContents = try Data(contentsOf: snapshot.entrypointURL)
        #expect(String(decoding: copiedContents, as: UTF8.self).contains("original"))
        #expect(!String(decoding: copiedContents, as: UTF8.self).contains("replacement"))
        #expect(snapshot.fingerprint == plugin.manifestFingerprint)

        await snapshotter.remove(snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.directoryURL.path))
    }
}
