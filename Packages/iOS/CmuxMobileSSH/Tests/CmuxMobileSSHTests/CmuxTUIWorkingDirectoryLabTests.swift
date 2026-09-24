@testable import CmuxMobileSSH
import Foundation
import Testing

/// The Files chip opens SFTP at a cmux-tui terminal's live directory
/// (`process-info` `foreground_cwd`). Run with
/// `CMUX_SSH_LAB=/tmp/cmux-ssh-lab CMUX_TUI_BIN=/abs/path/cmux-tui swift test --filter CmuxTUIWorkingDirectory`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil
    && ProcessInfo.processInfo.environment["CMUX_TUI_BIN"] != nil))
struct CmuxTUIWorkingDirectoryLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""
    let binary = ProcessInfo.processInfo.environment["CMUX_TUI_BIN"] ?? ""

    @Test(.timeLimit(.minutes(1))) func workingDirectoryFollowsCd() async throws {
        let session = "cmux-lab-\(UUID().uuidString.lowercased())"
        defer { cleanUp(session: session) }
        let key = try SSHPrivateKeyParser.parse(try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        let ssh = try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
        let control = try await CmuxTUIRemote(binaryPath: binary).connect(on: ssh, session: session)
        let created = try await control.createWorkspace(name: "cwd", cols: 80, rows: 24)
        let surface = try #require(created.terminal?.surface)
        let target = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true
        ).resolvingSymlinksInPath().path

        try await control.send(Data("cd \(CmuxTUIShell.quote(target))\r".utf8), to: surface)
        var directory: String?
        for _ in 0..<100 {
            directory = try await control.workingDirectory(surface: surface)
            if directory.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == target { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == target)
        await control.close()
        await ssh.close()
    }

    private func cleanUp(session: String) {
        let quoted = CmuxTUIShell.quote(session)
        let bin = CmuxTUIShell.quote(binary)
        _ = try? shell("""
        \(bin) server stop --session \(quoted) --json >/dev/null 2>&1
        token=$(\(bin) session \(quoted) reset-state --json 2>/dev/null | sed -n 's/.*"confirm_reset":"\\([^"]*\\)".*/\\1/p')
        [ -n "$token" ] && \(bin) session \(quoted) reset-state --force --confirm-reset "$token" >/dev/null 2>&1
        true
        """)
    }
}
