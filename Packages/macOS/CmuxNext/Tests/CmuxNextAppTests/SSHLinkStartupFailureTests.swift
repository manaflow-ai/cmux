import CmuxNextRemote
import Foundation
import Testing

@Suite(.serialized) struct SSHLinkStartupFailureTests {
    enum Failure: CaseIterable, Sendable { case sshLaunch, bundledProtocol, paths, clientLaunch }

    @Test(arguments: Failure.allCases)
    func localStartupFailuresPublishRecovery(_ failure: Failure) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = #"{"app":"cmux-tui","version":"0.1.0","remote_protocol":7,"os":"macos","arch":"aarch64"}"#
        let ssh = try script(root, "ssh", """
            #!/bin/sh
            cat >/dev/null
            echo 'cmux-probe-uname: Darwin arm64'
            echo '\(probe)'
            echo 'cmux-probe-end'
            """)
        let binary = try script(root, "cmux-tui", failure == .bundledProtocol ? "#!/bin/sh\necho invalid-json\n" : """
            #!/bin/sh
            echo '\(probe)'
            \(failure == .clientLaunch ? "rm -- \"$0\"" : "")
            """)
        let paths = root.appendingPathComponent("state")
        if failure == .paths { try Data().write(to: paths) }
        let link = SSHMachineLink(host: try SSHHost(destination: SSHDestination(parsing: "example.invalid")),
            binary: binary, paths: SSHPaths(root: paths),
            commandLine: SSHCommandLine(sshBinary: failure == .sshLaunch ? root.appendingPathComponent("missing").path : ssh.path),
            environment: { ProcessInfo.processInfo.environment }, onStatus: { _ in })
        await link.handle(.connect)
        do {
            _ = try await link.socketPath()
            Issue.record("Startup unexpectedly succeeded")
        } catch {
            guard case .failed(let cause) = await link.status else {
                Issue.record("Startup error was not published: \(await link.status)")
                await link.stop()
                return
            }
            #expect(!cause.isEmpty)
            #expect(await link.status.needsRecovery)
        }
        await link.stop()
    }

    private func script(_ root: URL, _ name: String, _ body: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try (body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
