import Foundation
import Testing
@testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    @Test
    func snapshotCanonicalPathsIgnoreDirectoryURLHint() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: root)
        let directoryURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = URL(fileURLWithPath: root.path, isDirectory: false)

        let canonicalDirectoryURL = await snapshotter.canonicalURL(directoryURL)
        let canonicalFileURL = await snapshotter.canonicalURL(fileURL)
        #expect(canonicalDirectoryURL == canonicalFileURL)
    }

    @Test
    func partialDirectoryLoadIgnoresUnrelatedRootEntryBudget() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.partial-reload",
            displayName: "Partial Reload",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        for index in 0 ..< CmuxPluginDirectoryLoader.maximumRootEntryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load(only: [manifest.id])

        #expect(report.failures.isEmpty)
        #expect(report.plugins.map(\.manifest.id) == [manifest.id])
    }

    @Test
    func approvalAndEnablementRetainPartialReloadsBeyondFullScanLimit() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let initialPluginIDs = (0 ..< CmuxPluginDirectoryLoader.maximumPluginCount).map {
            "dev.example.over-limit-\($0)"
        }
        for pluginID in initialPluginIDs {
            try Self.writePlugin(
                CmuxExtensionManifest.plugin(
                    id: pluginID,
                    displayName: pluginID,
                    entrypoint: "bin/plugin"
                ),
                to: root
            )
        }
        let extraPluginID = "dev.example.over-limit-extra"
        let extraManifest = CmuxExtensionManifest.plugin(
            id: extraPluginID,
            displayName: extraPluginID,
            entrypoint: "bin/plugin"
        )

        let registry = CmuxPluginRegistry(
            loader: CmuxPluginDirectoryLoader(directoryURL: root),
            permissionStore: CmuxPluginPermissionStore(storageURL: nil)
        )
        let initialSnapshot = await registry.reload()
        #expect(initialSnapshot.plugins.count == CmuxPluginDirectoryLoader.maximumPluginCount)

        try Self.writePlugin(extraManifest, to: root)
        let partialSnapshot = await registry.reload(affectedPluginIDs: [extraPluginID])
        #expect(partialSnapshot.plugins.count == CmuxPluginDirectoryLoader.maximumPluginCount + 1)

        let approvedSnapshot = try await registry.approveAll(pluginID: initialPluginIDs[0])
        #expect(approvedSnapshot.plugins.count == partialSnapshot.plugins.count)
        #expect(approvedSnapshot.plugins.first(where: { $0.plugin.manifest.id == initialPluginIDs[0] })?.isApproved == true)

        let disabledSnapshot = try await registry.setEnabled(false, pluginID: initialPluginIDs[0])
        #expect(disabledSnapshot.plugins.count == partialSnapshot.plugins.count)
        #expect(disabledSnapshot.plugins.first(where: { $0.plugin.manifest.id == initialPluginIDs[0] })?.isEnabled == false)

        let reenabledSnapshot = try await registry.setEnabled(true, pluginID: initialPluginIDs[0])
        #expect(reenabledSnapshot.plugins.count == partialSnapshot.plugins.count)
        #expect(reenabledSnapshot.plugins.first(where: { $0.plugin.manifest.id == initialPluginIDs[0] })?.isEnabled == true)
    }

    @Test
    func overlappingFullAndPartialReloadsRetainAllPluginUpdates() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pluginIDs = (0 ..< CmuxPluginDirectoryLoader.maximumPluginCount).map {
            "dev.example.overlap-\($0)"
        }
        for pluginID in pluginIDs.dropLast() {
            try Self.writePlugin(
                CmuxExtensionManifest.plugin(
                    id: pluginID,
                    displayName: pluginID,
                    entrypoint: "bin/plugin"
                ),
                to: root
            )
        }

        let registry = CmuxPluginRegistry(
            loader: CmuxPluginDirectoryLoader(directoryURL: root),
            permissionStore: CmuxPluginPermissionStore(storageURL: nil)
        )

        // Seed the registry so a partial reload always merges against the
        // complete prior report, regardless of which overlapping task reaches
        // the actor first. The newly added plugin is the affected directory.
        let initialSnapshot = await registry.reload()
        #expect(initialSnapshot.plugins.count == pluginIDs.count - 1)
        try Self.writePlugin(
            CmuxExtensionManifest.plugin(
                id: pluginIDs[pluginIDs.count - 1],
                displayName: pluginIDs[pluginIDs.count - 1],
                entrypoint: "bin/plugin"
            ),
            to: root
        )

        let fullReload = Task { await registry.reload() }
        let partialReload = Task {
            await registry.reload(affectedPluginIDs: [pluginIDs[pluginIDs.count - 1]])
        }

        let fullSnapshot = await fullReload.value
        let partialSnapshot = await partialReload.value
        let expectedIDs = Set(pluginIDs)
        #expect(Set(fullSnapshot.plugins.map(\.plugin.manifest.id)) == expectedIDs)
        #expect(Set(partialSnapshot.plugins.map(\.plugin.manifest.id)) == expectedIDs)
    }

    @Test
    func artifactFingerprintIncludesCaseMismatchedEntrypointInterpreter() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.case-insensitive-entrypoint",
            displayName: "Case Insensitive Entrypoint",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let pluginDirectory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let manifestData = try Data(
            contentsOf: pluginDirectory.appendingPathComponent("manifest.json")
        )
        let fingerprinter = CmuxPluginArtifactFingerprinter()

        let withoutOverride = try fingerprinter.fingerprint(
            manifestData: manifestData,
            pluginDirectoryURL: pluginDirectory,
            entrypointDeclaration: "BIN/PLUGIN"
        )
        let withOverride = try fingerprinter.fingerprint(
            manifestData: manifestData,
            pluginDirectoryURL: pluginDirectory,
            entrypointDeclaration: "BIN/PLUGIN",
            interpreterData: Data("different interpreter bytes".utf8)
        )

        #expect(withoutOverride != withOverride)
    }

    @Test
    func artifactFingerprintIgnoresFinderMetadata() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.finder-metadata",
            displayName: "Finder Metadata",
            entrypoint: "bin/plugin"
        )
        try Self.writePlugin(manifest, to: root)
        let pluginDirectory = root.appendingPathComponent(manifest.id, isDirectory: true)
        try Data("finder metadata".utf8).write(
            to: pluginDirectory.appendingPathComponent(".DS_Store")
        )
        try Data("resource fork".utf8).write(
            to: pluginDirectory.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("._plugin")
        )

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()
        #expect(report.plugins.count == 1)
        let plugin = try #require(report.plugins.first)
        try FileManager.default.removeItem(
            at: pluginDirectory.appendingPathComponent(".DS_Store")
        )
        try FileManager.default.removeItem(
            at: pluginDirectory.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("._plugin")
        )
        let cleanReport = await CmuxPluginDirectoryLoader(directoryURL: root).load()
        let cleanPlugin = try #require(cleanReport.plugins.first)
        #expect(plugin.manifestFingerprint == cleanPlugin.manifestFingerprint)
    }

    @Test
    func directoryLoaderRejectsManifestAndEntrypointSymlinkEscapes() async throws {
        let root = try Self.makeTemporaryDirectory()
        let outside = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let entrypointManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.entrypoint-link",
            displayName: "Entrypoint Link",
            entrypoint: "bin/plugin"
        )
        let entrypointDirectory = root.appendingPathComponent(
            entrypointManifest.id,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: entrypointDirectory.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entrypointManifest).write(
            to: entrypointDirectory.appendingPathComponent("manifest.json")
        )
        let outsideExecutable = outside.appendingPathComponent("plugin")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outsideExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: outsideExecutable.path
        )
        try FileManager.default.createSymbolicLink(
            at: entrypointDirectory.appendingPathComponent("bin/plugin"),
            withDestinationURL: outsideExecutable
        )

        let manifestDirectory = root.appendingPathComponent(
            "dev.example.manifest-link",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
        let outsideManifest = CmuxExtensionManifest.plugin(
            id: "dev.example.manifest-link",
            displayName: "Manifest Link",
            entrypoint: "bin/plugin"
        )
        let outsideManifestURL = outside.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(outsideManifest).write(to: outsideManifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestDirectory.appendingPathComponent("manifest.json"),
            withDestinationURL: outsideManifestURL
        )

        let linkedDirectoryID = "dev.example.directory-link"
        let outsidePluginDirectory = outside.appendingPathComponent(
            linkedDirectoryID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsidePluginDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(
            CmuxExtensionManifest.plugin(
                id: linkedDirectoryID,
                displayName: "Directory Link",
                entrypoint: "bin/plugin"
            )
        ).write(to: outsidePluginDirectory.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(linkedDirectoryID, isDirectory: true),
            withDestinationURL: outsidePluginDirectory
        )

        let report = await CmuxPluginDirectoryLoader(directoryURL: root).load()

        #expect(report.plugins.isEmpty)
        #expect(report.failures.count == 3)
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == linkedDirectoryID
                && failure.code == .invalidManifest
        })
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == entrypointManifest.id
                && failure.code == .missingEntrypoint
        })
        #expect(report.failures.contains { failure in
            failure.directoryURL.lastPathComponent == outsideManifest.id
                && failure.code == .invalidManifest
        })
    }
}
