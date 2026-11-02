@testable import CmuxNextCloudCredentials
import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud start replaces a Claude login the provider rejects (a reused machine's expired token) with the
/// account's own, as it gives a machine with none its first; anything else on the machine stays.
@Suite(.serialized)
struct CloudMachineLoginTests {
    static let token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789"
    static let fresh = "sk-ant-oat01-0123456789zyxwvutsrqponmlkjihgfedcba"

    @Test func onlyAMissingOrRejectedLoginIsReplaced() {
        #expect(CloudMachineLogin.none.needsLogin)
        #expect(CloudMachineLogin.rejected.needsLogin)
        #expect(!CloudMachineLogin.session.needsLogin)
        #expect(!CloudMachineLogin.cached.needsLogin)
        #expect(!CloudMachineLogin.working.needsLogin)
    }

    @Test func theProbesWordIsTheAnswerElseItsExitCode() {
        for login in CloudMachineLogin.allCases { #expect(CloudMachineLogin.parse(exitCode: 0, stdout: login.rawValue + "\n") == login) }
        // An old probe's bare exit code, or noise: 0 is a login that stays, as before.
        #expect(CloudMachineLogin.parse(exitCode: 0, stdout: "") == .working)
        #expect(CloudMachineLogin.parse(exitCode: 1, stdout: "") == .none)
        #expect(CloudMachineLogin.parse(exitCode: 127, stdout: "python3: not found") == .none)
    }

    @Test func theProbeCarriesAFingerprintNeverAToken() {
        let fingerprint = CloudMachineLogin.fingerprint(Data(Self.token.utf8))
        #expect(fingerprint.count == 64)
        let probe = CloudMachineLogin.probe(cachedFingerprint: fingerprint)
        #expect(probe.contains("cmux_agent_has_own_login claude"))
        #expect(probe.contains(fingerprint))
        #expect(!probe.contains("sk-ant"))
        #expect(probe.contains("https://api.anthropic.com/"))
        // A Python that fails after the image found a login keeps that login.
        #expect(probe.contains("<<'CMUX_LOGIN_PROBE' || echo working\n"))
    }

    // MARK: The probe on a scratch machine

    /// A scratch machine: the image's agent-auth.sh under a policy folder, and a work user's HOME.
    struct Machine {
        let root: URL, home: URL, policy: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-login-\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            policy = root.appendingPathComponent("policy")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: policy, withIntermediateDirectories: true)
            let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            let auth = try String(contentsOf: repo.appendingPathComponent("web/services/vms/images/devbox/agent-auth.sh"), encoding: .utf8)
                .replacingOccurrences(of: "/etc/cmux", with: policy.path)
            try Data(auth.utf8).write(to: policy.appendingPathComponent("agent-auth.sh"))
            try Data().write(to: policy.appendingPathComponent("agent-config.sh"))
        }

        /// As ``CloudCredentialInstaller`` leaves a transferred login.
        func installed(_ token: String) throws {
            try JSONSerialization.data(withJSONObject: ["env": ["CLAUDE_CODE_OAUTH_TOKEN": token]]).write(to: home.appendingPathComponent(".claude/settings.json"))
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]]).write(to: home.appendingPathComponent(".claude/.credentials.json"))
        }

        /// `execHome`: the exec's own HOME (the classic route's exec runs as root, HOME /root); the
        /// probe reads `cmux`'s home whatever it is.
        func probe(cached: String?, endpoint: String, execHome: URL? = nil) async throws -> CloudMachineLogin {
            let command = CloudMachineLogin.probe(cachedFingerprint: cached.map { CloudMachineLogin.fingerprint(Data($0.utf8)) }, endpoint: endpoint)
                .replacingOccurrences(of: "/etc/cmux", with: policy.path)
                .replacingOccurrences(of: "pwd.getpwnam('cmux').pw_dir", with: CloudCredentialInstaller.quote(home.path))
            let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                environment: ["PATH": "/usr/bin:/bin", "HOME": (execHome ?? home).path], timeout: .seconds(20), clock: ContinuousClock())
            let out = String(decoding: ran.stdout, as: UTF8.self)
            #expect(!out.contains("sk-ant"))
            return CloudMachineLogin.parse(exitCode: Int(ran.status), stdout: out)
        }
    }

    /// A local provider that answers `/<status>` with that status, and 400 unless the token came as the
    /// bearer with the OAuth beta header.
    final class Provider {
        let process = Process()
        let port: Int
        init(token: String) throws {
            let server = """
                import http.server, sys
                class H(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        code = int(self.path.strip('/').split('?')[0])
                        if self.headers.get('authorization') != 'Bearer ' + sys.argv[1] or self.headers.get('anthropic-beta') != 'oauth-2025-04-20': code = 400
                        body = b'{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}'
                        self.send_response(code); self.send_header('content-length', str(len(body))); self.end_headers(); self.wfile.write(body)
                    def log_message(self, *args): pass
                s = http.server.HTTPServer(('127.0.0.1', 0), H)
                print(s.server_address[1], flush=True)
                s.serve_forever()
                """
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", "-c", server, token]
            process.standardOutput = out
            try process.run()
            let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CocoaError(.fileReadCorruptFile) }
            self.port = port
        }
        func url(_ status: Int) -> String { "http://127.0.0.1:\(port)/\(status)?limit=1" }
        deinit { process.terminate() }
    }

    @Test func aRejectedTokenIsReplacedAndEveryOtherAnswerKeepsIt() async throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        let provider = try Provider(token: Self.token)
        // No login yet: the image's own detection says so before any provider is asked.
        #expect(try await machine.probe(cached: Self.fresh, endpoint: provider.url(200)) == .none)
        try machine.installed(Self.token)
        // The capture's case: a reused machine's stale login, a fresh one cached on the Mac.
        #expect(try await machine.probe(cached: Self.fresh, endpoint: provider.url(401)) == .rejected)
        #expect(try await machine.probe(cached: nil, endpoint: provider.url(401)) == .rejected)
        #expect(try await machine.probe(cached: Self.fresh, endpoint: provider.url(200)) == .working)
        // A 403 (a scope, a plan) or a provider that can't be reached is not a rejected token.
        #expect(try await machine.probe(cached: Self.fresh, endpoint: provider.url(403)) == .working)
        #expect(try await machine.probe(cached: Self.fresh, endpoint: "http://127.0.0.1:1/") == .working)
        // The machine already has cmux's own login: never replaced again (no loop), whatever the provider says.
        #expect(try await machine.probe(cached: Self.token, endpoint: provider.url(401)) == .cached)
    }

    /// The classic `/api/vm` exec runs as root: its HOME is not `cmux`'s, where the login is. A working
    /// login there must not read as none (which would replace it).
    @Test func theProbeReadsTheWorkUsersHomeNotTheExecs() async throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        let root = machine.root.appendingPathComponent("root-home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try machine.installed(Self.token)
        #expect(try await machine.probe(cached: Self.token, endpoint: "http://127.0.0.1:1/", execHome: root) == .cached)
        #expect(try await machine.probe(cached: Self.fresh, endpoint: "http://127.0.0.1:1/", execHome: root) == .working)
        #expect(CloudMachineLogin.probe(cachedFingerprint: nil).contains("pwd.getpwnam('cmux').pw_dir"))
        // The config is sourced before HOME moves, so it never writes into cmux's home as root.
        let probe = CloudMachineLogin.probe(cachedFingerprint: nil)
        let config = try #require(probe.range(of: "agent-config.sh")), moved = try #require(probe.range(of: "export HOME"))
        #expect(config.lowerBound < moved.lowerBound)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
    }

    @Test func aSessionClaudeRefreshesItselfIsLeftAlone() async throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": Self.token, "refreshToken": "refresh"]])
            .write(to: machine.home.appendingPathComponent(".claude/.credentials.json"))
        #expect(try await machine.probe(cached: Self.fresh, endpoint: "http://127.0.0.1:1/") == .session)
    }
}
