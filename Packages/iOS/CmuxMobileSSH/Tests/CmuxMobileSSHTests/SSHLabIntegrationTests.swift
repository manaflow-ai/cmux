import CmuxMobileSSH
import Foundation
import Testing

/// Live tests against a local sshd. Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`
/// after starting the lab (see docs/prd/ios-direct-ssh.md, Verification).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct SSHLabIntegrationTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""
    var endpoint: SSHEndpoint { SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()) }

    func credential() throws -> SSHCredential {
        let text = try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)
        return .privateKey(try SSHParsedPrivateKey(openSSH: text).key)
    }

    @Test func execRunsAndReportsStatus() async throws {
        let connection = try await SSHConnection.connect(
            to: endpoint,
            credentials: [try credential()],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
        let result = try await connection.exec("printf hello; printf oops >&2; exit 3")
        #expect(result.stdoutString == "hello")
        #expect(result.stderrString == "oops")
        #expect(result.exitStatus == 3)
        await connection.close()
    }

    @Test func hostKeyFingerprintMatchesSSHKeygen() async throws {
        let verifier = RecordingVerifier(accept: true)
        let connection = try await SSHConnection.connect(to: endpoint, credentials: [try credential()], hostKeyVerifier: verifier)
        let expected = try shell("ssh-keygen -lf \(lab)/ssh_host_ed25519_key.pub | awk '{print $2}'")
        #expect(connection.hostKey.sha256Fingerprint == expected)
        #expect(await verifier.seen == [connection.hostKey])
        await connection.close()
    }

    @Test func rejectedHostKeyAbortsBeforeAuth() async throws {
        await #expect(throws: SSHConnectionError.self) {
            _ = try await SSHConnection.connect(
                to: endpoint,
                credentials: [try credential()],
                hostKeyVerifier: RecordingVerifier(accept: false)
            )
        }
    }

    /// The trust prompt can take as long as the user needs: verification
    /// time is not part of the handshake budget.
    @Test(.timeLimit(.minutes(1))) func slowVerifierDoesNotTimeOutTheHandshake() async throws {
        let connection = try await SSHConnection.connect(
            to: endpoint,
            credentials: [try credential()],
            hostKeyVerifier: DelayedVerifier(delay: .seconds(2), accept: true),
            connectTimeout: .seconds(1)
        )
        #expect(try await connection.exec("echo ok").stdoutString == "ok\n")
        await connection.close()
    }

    /// Declining surfaces as `hostKeyRejected` right away, not as a timeout,
    /// even when the user took longer than the budget to decide.
    @Test(.timeLimit(.minutes(1))) func declinedHostKeyReportsRejectionNotTimeout() async throws {
        for delay in [Duration.zero, .seconds(2)] {
            let started = ContinuousClock.now
            do {
                _ = try await SSHConnection.connect(
                    to: endpoint,
                    credentials: [try credential()],
                    hostKeyVerifier: DelayedVerifier(delay: delay, accept: false),
                    connectTimeout: .seconds(1)
                )
                Issue.record("a declined host key must not connect")
            } catch SSHConnectionError.hostKeyRejected {
                #expect(ContinuousClock.now - started < delay + .seconds(1))
            }
        }
    }

    /// A declined key on the target behind a jump host is reported as the
    /// rejection, not as a transport failure of the tunnel.
    @Test(.timeLimit(.minutes(1))) func declinedHostKeyBehindJumpHostReportsRejection() async throws {
        let bastion = try await SSHConnection.connect(to: endpoint, credentials: [try credential()], hostKeyVerifier: RecordingVerifier(accept: true))
        await #expect(throws: SSHConnectionError.hostKeyRejected(.unknown(presented: bastion.hostKey))) {
            _ = try await SSHConnection.connect(
                to: endpoint,
                credentials: [try credential()],
                hostKeyVerifier: DelayedVerifier(delay: .seconds(2), accept: false),
                via: bastion,
                connectTimeout: .seconds(1)
            )
        }
        await bastion.close()
    }

    @Test func wrongKeyFailsAuthentication() async throws {
        let stranger = try SSHParsedPrivateKey(openSSH: try shell("rm -f /tmp/cmux-ssh-stranger*; ssh-keygen -q -t ed25519 -N '' -f /tmp/cmux-ssh-stranger && cat /tmp/cmux-ssh-stranger", trim: false))
        await #expect(throws: (any Error).self) {
            _ = try await SSHConnection.connect(
                to: endpoint,
                credentials: [.privateKey(stranger.key)],
                hostKeyVerifier: RecordingVerifier(accept: true)
            )
        }
    }

    @Test func ptyShellEchoesAndResizes() async throws {
        let connection = try await SSHConnection.connect(to: endpoint, credentials: [try credential()], hostKeyVerifier: RecordingVerifier(accept: true))
        let shell = try await connection.openSession(
            pty: SSHPTYRequest(columns: 80, rows: 24),
            start: .exec("/bin/sh")
        )
        try await shell.write(Data("stty size; echo MARK$((0+1))\n".utf8))
        var output = try await collect(shell, until: "MARK1\r\n")
        #expect(output.contains("24 80"))
        try await shell.resize(columns: 120, rows: 40)
        try await shell.write(Data("stty size; echo MARK$((0+2))\n".utf8))
        output = try await collect(shell, until: "MARK2\r\n")
        #expect(output.contains("40 120"))
        try await shell.write(Data("exit 0\n".utf8))
        await connection.close()
    }

    @Test func jumpHostTunnelsSecondConnection() async throws {
        let bastion = try await SSHConnection.connect(to: endpoint, credentials: [try credential()], hostKeyVerifier: RecordingVerifier(accept: true))
        let target = try await SSHConnection.connect(
            to: endpoint,
            credentials: [try credential()],
            hostKeyVerifier: RecordingVerifier(accept: true),
            via: bastion
        )
        let result = try await target.exec("echo through-jump")
        #expect(result.stdoutString == "through-jump\n")
        await target.close()
        await bastion.close()
    }

    @Test func sftpSubsystemOpens() async throws {
        let connection = try await SSHConnection.connect(to: endpoint, credentials: [try credential()], hostKeyVerifier: RecordingVerifier(accept: true))
        let sftp = try await connection.openSession(start: .subsystem("sftp"))
        await sftp.close()
        await connection.close()
    }

    /// Reads until `marker` appears. Callers compute the marker in the shell
    /// (`$((0+1))`) so the PTY echo of the typed line never contains it.
    private func collect(_ shell: SSHSessionChannel, until marker: String) async throws -> String {
        var text = ""
        for await event in shell.events {
            if case .stdout(let data) = event { text += String(decoding: data, as: UTF8.self) }
            if text.components(separatedBy: marker).count >= 2 { return text }
        }
        return text
    }
}

actor RecordingVerifier: SSHHostKeyVerifier {
    let accept: Bool
    private(set) var seen: [SSHHostKey] = []
    init(accept: Bool) { self.accept = accept }
    nonisolated func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        await record(key)
        return accept
    }
    private func record(_ key: SSHHostKey) { seen.append(key) }
}

/// Answers after `delay`, like a user reading a trust prompt.
struct DelayedVerifier: SSHHostKeyVerifier {
    let delay: Duration
    let accept: Bool
    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        try? await Task.sleep(for: delay)
        return accept
    }
}

func shell(_ command: String, trim: Bool = true) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return trim ? out.trimmingCharacters(in: .whitespacesAndNewlines) : out
}
