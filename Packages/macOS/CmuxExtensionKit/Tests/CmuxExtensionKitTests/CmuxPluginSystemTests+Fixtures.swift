import Foundation
@testable import CmuxExtensionKit

extension CmuxPluginSystemTests {
    static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func writePlugin(
        _ manifest: CmuxExtensionManifest,
        to root: URL,
        executableContents: String = "#!/bin/sh\nexit 0\n"
    ) throws {
        let directory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let entrypoint = directory.appendingPathComponent(manifest.entrypoint ?? "bin/plugin")
        try FileManager.default.createDirectory(
            at: entrypoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json")
        )
        try Data(executableContents.utf8).write(to: entrypoint)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entrypoint.path
        )
    }
}
