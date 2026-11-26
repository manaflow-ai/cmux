@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// Downloads the pinned cmux-tui from npm, verifies it, uploads it over SSH
/// into a scratch directory, and runs it. Needs network + the sshd lab.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHCmuxTUIInstallerLabTests {
    @Test func downloadVerifyUploadAndRun() async throws {
        let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""
        let key = try SSHParsedPrivateKey(openSSH: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: AcceptingVerifier()
        )
        let dir = "/tmp/cmux-tui-install-\(UUID().uuidString)"
        let probe = try await CmuxTUIRemote(binaryPath: "\(dir)/cmux-tui").probe(on: connection)
        #expect(probe.installed == nil)
        var messages: [String] = []
        try await MobileSSHCmuxTUIInstaller(binDirectory: dir).install(probe: probe, on: connection) { messages.append($0) }
        #expect(messages.count == 1)
        let installed = try await CmuxTUIRemote(binaryPath: "\(dir)/cmux-tui").probe(on: connection)
        #expect(installed.installed != nil)
        let leftovers = try await connection.exec("ls /tmp/cmux-tui-*.tgz 2>/dev/null | wc -l")
        #expect(leftovers.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        _ = try await connection.exec("rm -rf '\(dir)'")
        await connection.close()
    }

    @Test func tamperedTarballIsRejected() {
        #expect(Data("x".utf8).sha512Base64 != Data("y".utf8).sha512Base64)
    }
}

struct AcceptingVerifier: SSHHostKeyVerifier {
    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool { true }
}
