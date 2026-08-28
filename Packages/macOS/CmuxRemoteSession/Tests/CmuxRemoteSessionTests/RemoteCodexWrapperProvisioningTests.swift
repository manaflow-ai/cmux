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

        let installed = root.appendingPathComponent(".cmux/bin/cmux-codex-wrapper")
        #expect(try String(contentsOf: installed, encoding: .utf8) == wrapper + "\n")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))

        let launch = Process()
        let output = Pipe()
        launch.executableURL = URL(fileURLWithPath: "/bin/sh")
        launch.arguments = ["-c", "\"$CMUX_CODEX_WRAPPER_SHIM\""]
        launch.environment = [
            "CMUX_CODEX_WRAPPER_SHIM": installed.path,
            "HOME": root.path,
            "PATH": root.appendingPathComponent(".cmux/bin").path + ":/usr/bin:/bin",
        ]
        launch.standardOutput = output
        try launch.run()
        launch.waitUntilExit()
        #expect(launch.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            == "remote-codex-wrapper\n")
    }

    @Test("relay metadata fails and removes the temporary Codex wrapper when chmod fails")
    func codexWrapperInstallFailureIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-codex-wrapper-failure-\(UUID().uuidString)", isDirectory: true)
        let fakeBin = root.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chmod = fakeBin.appendingPathComponent("chmod")
        try """
        #!/bin/sh
        count_file="$HOME/chmod-count"
        count=0
        [ ! -r "$count_file" ] || count="$(cat "$count_file")"
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        [ "$count" -ne 2 ] || exit 23
        exec /bin/chmod "$@"
        """.write(to: chmod, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chmod.path)

        let script = RemoteSessionCoordinator.remoteRelayMetadataInstallScript(
            daemonRemotePath: "/bin/true",
            relayPort: 64_044,
            relayID: "relay-test",
            relayToken: String(repeating: "a", count: 64),
            codexWrapperScript: "#!/bin/sh\nexit 0"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": root.path, "PATH": fakeBin.path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        let bin = root.appendingPathComponent(".cmux/bin")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        #expect(!remaining.contains(where: { $0.hasPrefix(".codex-wrapper.tmp.") }))
        #expect(!remaining.contains("cmux-codex-wrapper"))
    }
}
