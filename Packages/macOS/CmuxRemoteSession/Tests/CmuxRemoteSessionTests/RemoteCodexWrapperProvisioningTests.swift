import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote Codex wrapper provisioning")
struct RemoteCodexWrapperProvisioningTests {
    @Test("relay metadata installs the bundled Codex wrapper on the remote PATH")
    func installsBundledCodexWrapper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-codex-wrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = """
        #!/bin/sh
        printf '%s\\n' remote-codex-wrapper
        """
        let script = RemoteSessionCoordinator.remoteRelayMetadataInstallScript(
            daemonRemotePath: "/bin/true",
            relayPort: 64_044,
            relayID: "relay-test",
            relayToken: String(repeating: "a", count: 64),
            codexWrapperScript: wrapper
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let installed = root.appendingPathComponent(".cmux/bin/codex")
        #expect(try String(contentsOf: installed, encoding: .utf8) == wrapper + "\n")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }
}
