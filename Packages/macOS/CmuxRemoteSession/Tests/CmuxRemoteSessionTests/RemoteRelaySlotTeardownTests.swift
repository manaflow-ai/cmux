import Foundation
import Testing

@testable import CmuxRemoteSession

@Suite
struct RemoteRelaySlotTeardownTests {
    @Test
    func cleanupStopsPersistentSlotAndRemovesShellState() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-slot-teardown-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64008.shell")
        let daemonURL = home.appendingPathComponent("cmuxd-remote-test")
        let shutdownArgumentsURL = home.appendingPathComponent("shutdown.args")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "shell state".write(
            to: shellDirectory.appendingPathComponent(".bashrc"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$HOME/shutdown.args\"\n".write(
            to: daemonURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemonURL.path)
        try daemonURL.path.write(
            to: relayDirectory.appendingPathComponent("64008.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-test-slot".write(
            to: relayDirectory.appendingPathComponent("64008.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "auth".write(
            to: relayDirectory.appendingPathComponent("64008.auth"),
            atomically: true,
            encoding: .utf8
        )
        try "pts/1".write(
            to: relayDirectory.appendingPathComponent("64008.tty"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(relayPort: 64008),
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: shutdownArgumentsURL.path))
        if fileManager.fileExists(atPath: shutdownArgumentsURL.path) {
            let arguments = try String(contentsOf: shutdownArgumentsURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(arguments == "serve --persistent-stop --slot ssh-test-slot")
        }
        #expect(!fileManager.fileExists(atPath: shellDirectory.path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.auth").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.daemon_path").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.slot").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.tty").path))
    }
}
