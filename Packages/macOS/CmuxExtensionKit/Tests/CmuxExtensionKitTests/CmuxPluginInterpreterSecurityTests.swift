import Foundation
import Testing
@testable import CmuxExtensionKit

@Suite(.serialized)
struct CmuxPluginInterpreterSecurityTests {
    @Test
    func mutableInterpreterIsCopiedBeforeLaunch() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let interpreterRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        let snapshotRoot = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: interpreterRoot)
            try? FileManager.default.removeItem(at: snapshotRoot)
        }

        let interpreterURL = interpreterRoot.appendingPathComponent("interpreter")
        try writeInterpreter(
            "#!/bin/sh\nprintf original > \"$CMUX_TEST_INTERPRETER_MARKER\"\n",
            to: interpreterURL
        )
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.mutable-interpreter",
            displayName: "Mutable Interpreter",
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!(interpreterURL.path)\n"
        )

        let plugin = try #require(
            (await CmuxPluginDirectoryLoader(directoryURL: root).load()).plugins.first
        )
        let snapshotter = CmuxPluginExecutionSnapshotter(rootDirectoryURL: snapshotRoot)
        let snapshot = try await snapshotter.makeSnapshot(for: plugin)
        #expect(snapshot.interpreterFileDescriptor != nil)

        try writeInterpreter(
            "#!/bin/sh\nprintf replacement > \"$CMUX_TEST_INTERPRETER_MARKER\"\n",
            to: interpreterURL,
            atomically: false
        )
        let markerURL = root.appendingPathComponent("interpreter-marker")
        let status = try run(snapshot: snapshot, markerURL: markerURL)

        #expect(status == 0)
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "original\n")
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
        try writeInterpreter("#!/bin/sh\nexit 0\n", to: interpreterURL)
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
            executableContents: "#!(interpreterURL.path)\n"
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
        #expect((await registry.snapshot()).plugins.first?.permissions == .none)
        do {
            _ = try await registry.sessionToken(pluginID: manifest.id)
            Issue.record("Changing an approved interpreter must invalidate its grant")
        } catch let error as CmuxPluginAuthorizationError {
            #expect(error == .disabled)
        }
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

    private func run(
        snapshot: CmuxPluginExecutionSnapshot,
        markerURL: URL
    ) throws -> Int32 {
        let process = Process()
        let gate = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
        process.arguments = [
            "-c",
            "read -r cmuxLaunchGate || true; [ \"$cmuxLaunchGate\" = cmux-ready ] || exit 126; exec 3>&1; exec 4>&2; exec 1>/dev/null 2>/dev/null; exec /dev/fd/4 \"$@\" /dev/fd/3",
            "cmux-plugin-launch-gate",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_INTERPRETER_MARKER"] = markerURL.path
        process.environment = environment
        process.standardInput = gate
        process.standardOutput = FileHandle(
            fileDescriptor: snapshot.entrypointFileDescriptor,
            closeOnDealloc: false
        )
        process.standardError = FileHandle(
            fileDescriptor: try #require(snapshot.interpreterFileDescriptor),
            closeOnDealloc: false
        )
        try process.run()
        try gate.fileHandleForReading.close()
        try gate.fileHandleForWriting.write(contentsOf: Data("cmux-ready\n".utf8))
        try gate.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
