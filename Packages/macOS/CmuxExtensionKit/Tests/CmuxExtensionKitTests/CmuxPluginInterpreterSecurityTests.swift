import Darwin
import Foundation
import Testing
@testable import CmuxExtensionKit

@Suite(.serialized)
struct CmuxPluginInterpreterSecurityTests {
    @Test
    func mutableInterpreterSnapshotRetainsOriginalBytes() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let interpreterRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let snapshotRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: interpreterRoot)
            try? FileManager.default.removeItem(at: snapshotRoot)
        }

        let interpreterURL = interpreterRoot.appendingPathComponent("interpreter")
        try writeBinaryInterpreter(to: interpreterURL)
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.mutable-interpreter",
            displayName: "Mutable Interpreter",
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!\(interpreterURL.path)\n"
        )

        let plugin = try #require(
            (await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first
        )
        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: snapshotRoot)
        let snapshot = try await snapshotter.makeSnapshot(for: plugin)
        #expect(snapshot.interpreterFileDescriptor != nil)
        let copiedInterpreterURL = snapshot.directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(".cmux-interpreter/executable", isDirectory: false)
        let copiedBytes = try Data(contentsOf: copiedInterpreterURL)

        try writeInterpreter(
            "#!/bin/sh\nprintf replacement > \"$CMUX_TEST_INTERPRETER_MARKER\"\n",
            to: interpreterURL,
            atomically: false
        )
        #expect(try Data(contentsOf: copiedInterpreterURL) == copiedBytes)
        #expect(!(await snapshotter.verify(snapshot)))
        await snapshotter.remove(snapshot)
    }

    @Test
    func mutableInterpreterChangesInvalidateApproval() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let interpreterRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: interpreterRoot)
        }

        let interpreterURL = interpreterRoot.appendingPathComponent("interpreter")
        try writeBinaryInterpreter(to: interpreterURL)
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.interpreter-approval",
            displayName: "Interpreter Approval",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!\(interpreterURL.path)\n"
        )

        let loader = CmuxPluginDirectoryLoader(directoryURL: root)
        let store = CmuxPluginPermissionStore(storageURL: nil)
        let registry = CmuxPluginRegistry(loader: loader, permissionStore: store)
        _ = await registry.reload()
        let original = try #require((await loader.load()).plugins.first)
        try await store.approveAll(for: original)
        _ = await registry.reload()
        _ = try await registry.sessionToken(pluginID: manifest.id)

        try writeInterpreter("#!/bin/sh\nprintf changed\n", to: interpreterURL, atomically: false)
        let changed = try #require((await loader.load()).plugins.first)
        #expect(changed.manifestFingerprint != original.manifestFingerprint)

        _ = await registry.reload()
        #expect((await registry.snapshot()).plugins.first?.permissions == CmuxPluginPermissions.none)
        do {
            _ = try await registry.sessionToken(pluginID: manifest.id)
            Issue.record("Changing an approved interpreter must invalidate its grant")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .disabled)
        }
    }

    @Test
    func nestedAndEnvInterpretersAreRejected() async throws {
        let cases = [
            ("nested", "nested-interpreter", "#!/bin/sh\nexit 0\n"),
            ("env", "env", "#!/bin/sh\nexit 0\n"),
        ]

        for (idSuffix, interpreterName, interpreterContents) in cases {
            let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
            let interpreterRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
            let snapshotRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: interpreterRoot)
                try? FileManager.default.removeItem(at: snapshotRoot)
            }

            let interpreterURL = interpreterRoot.appendingPathComponent(interpreterName)
            try writeInterpreter(interpreterContents, to: interpreterURL)
            let manifest = CmuxExtensionManifest.plugin(
                id: "dev.example.\(idSuffix)-interpreter",
                displayName: "\(idSuffix) interpreter",
                entrypoint: "bin/plugin"
            )
            try CmuxPluginSystemTests.writePlugin(
                manifest,
                to: root,
                executableContents: "#!\(interpreterURL.path)\n"
            )
            let plugin = try #require(
                (await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first
            )
            let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: snapshotRoot)

            do {
                let snapshot = try await snapshotter.makeSnapshot(for: plugin)
                await snapshotter.remove(snapshot)
                Issue.record("Interpreter indirection must be rejected: \(interpreterName)")
            } catch let error as CmuxPluginExecutionSnapshotError {
                #expect(error == .invalidInterpreter)
            }
        }
    }

    @Test
    func snapshotVerificationRejectsOwnerClearedRewrite() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let snapshotRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: snapshotRoot)
        }

        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.snapshot-verifier",
            displayName: "Snapshot Verifier",
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(manifest, to: root)
        let plugin = try #require(
            (await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first
        )
        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: snapshotRoot)
        let snapshot = try await snapshotter.makeSnapshot(for: plugin)
        #expect(await snapshotter.verify(snapshot))

        let descriptor = Darwin.open(snapshot.entrypointURL.path, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(Darwin.fchflags(descriptor, UInt32(0)) == 0)
            Darwin.close(descriptor)
        }
        let handle = try FileHandle(forWritingTo: snapshot.entrypointURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("#!/bin/sh\nprintf tampered\n".utf8))
        try handle.close()

        #expect(!(await snapshotter.verify(snapshot)))
        await snapshotter.remove(snapshot)
    }

    private func writeInterpreter(
        _ contents: String,
        to url: URL,
        atomically: Bool = true
    ) throws {
        if atomically {
            try Data(contents.utf8).write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.close()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func writeBinaryInterpreter(to url: URL) throws {
        try Data(contentsOf: URL(fileURLWithPath: "/bin/sh"))
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

}
