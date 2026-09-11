import Foundation
import Testing
@testable import CmuxExtensionKit

struct CmuxPluginShebangSecurityTests {
    @Test(arguments: [
        "/bin/sh /tmp/unsealed-plugin.sh",
        "/bin/sh -c exit",
        "/bin/sh -e",
        "/usr/bin/python3 -m external_module",
        "/usr/bin/python3 -c print(1)",
        "/usr/bin/python3 -u"
    ])
    func rejectsInterpreterArguments(_ declaration: String) {
        #expect(throws: CmuxPluginShebang.ParseError.self) {
            try CmuxPluginShebang.parse(prefix: Data("#!\(declaration)\n".utf8))
        }
    }

    @Test(arguments: ["/bin/sh", "/usr/bin/python3"])
    func acceptsArgumentFreeInterpreters(_ interpreter: String) throws {
        let parsed = try CmuxPluginShebang.parse(prefix: Data("#! \(interpreter) \r\n".utf8))
        let shebang = try #require(parsed)
        #expect(shebang.interpreterPath == interpreter)
        #expect(shebang.arguments.isEmpty)
    }

    @Test
    func externalProgramArgumentCannotReceiveAnApproval() async throws {
        let root = try CmuxPluginSystemTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalProgram = root.appendingPathComponent("outside-bundle.sh")
        try Data("exit 0\n".utf8).write(to: externalProgram)
        let manifest = CmuxExtensionManifest.plugin(
            id: "dev.example.shebang-argument",
            displayName: "Shebang Argument",
            pluginScopes: [.eventHooks],
            eventSubscriptions: [.workspaceCreated],
            entrypoint: "bin/plugin"
        )
        try CmuxPluginSystemTests.writePlugin(
            manifest,
            to: root,
            executableContents: "#!/bin/sh \(externalProgram.path)\nexit 0\n"
        )
        let registry = CmuxPluginRegistry(
            loader: CmuxPluginDirectoryLoader(directoryURL: root),
            permissionStore: CmuxPluginPermissionStore(storageURL: nil)
        )

        let snapshot = await registry.reload()
        #expect(snapshot.plugins.isEmpty)
        #expect(snapshot.failures.count == 1)
        await #expect(throws: CmuxPluginAuthorizationError.unknownPlugin) {
            try await registry.approveAll(pluginID: manifest.id)
        }
    }
}
