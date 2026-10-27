@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCredentialTransferTests {
    static let token = Data("sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    static let codex = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id"},"OPENAI_API_KEY":null}"#.utf8)

    final class Recorder {
        var commands: [String] = []
        var writes: [(String, Data)] = []
        var logins = 0, stores = 0
        var cached: Data?
        var owner = true
        var team: String? = "team"
        var user: String? = "user"
        var onAcquire: (() throws -> Void)?
        var onWrite: (() -> Void)?
        var effects: CloudCredentialTransfer.Effects {
            .init(exec: { self.commands.append($0); return self.owner ? 0 : 70 },
                  write: { self.writes.append(($0, $1)); self.onWrite?() }, load: { self.cached },
                  acquire: { self.logins += 1; try self.onAcquire?(); return CloudCredentialTransferTests.token },
                  store: { self.stores += 1; self.cached = $0 })
        }
        var transfer: CloudCredentialTransfer {
            .init(provider: .claude, machineID: "vm-one", teamID: "team", userID: "user", openTerminal: { _ in false })
        }
        func run(confirmed: Bool = true, refresh: Bool = false) async throws {
            try await transfer.run(currentTeamID: { self.team }, currentUserID: { self.user },
                                   confirmed: confirmed, refresh: refresh, effects: effects)
        }
    }

    @Test func noConsentHasNoEffects() async {
        let r = Recorder()
        await #expect(throws: CloudCredentialTransfer.Failure.consentRequired) { try await r.run(confirmed: false) }
        #expect(r.commands.isEmpty && r.writes.isEmpty && r.logins == 0 && r.stores == 0)
    }

    @Test func sharedMachineNeverReadsOrAcquiresCredentials() async {
        let r = Recorder(); r.owner = false
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.writes.isEmpty && r.logins == 0 && r.stores == 0)
    }

    @Test func firstTransferStoresThenDeliversAndRepeatReusesScopedCache() async throws {
        let r = Recorder()
        try await r.run(); try await r.run()
        #expect(r.logins == 1 && r.stores == 1 && r.writes.count == 2)
        #expect(r.writes.allSatisfy { $0.1 == Self.token })
        #expect(r.commands.allSatisfy { !$0.contains(String(decoding: Self.token, as: UTF8.self)) })
        try await r.run(refresh: true)
        #expect(r.logins == 2 && r.stores == 2)
    }

    @Test(arguments: [true, false])
    func accountOrTeamSwitchDuringLoginPreventsStoreAndDelivery(changeUser: Bool) async {
        let r = Recorder()
        r.onAcquire = { if changeUser { r.user = "other" } else { r.team = "other" } }
        await #expect(throws: CloudCredentialTransfer.Failure.scopeChanged) { try await r.run() }
        #expect(r.writes.isEmpty && r.stores == 0)
    }

    @Test func cancelledLoginNeverStoresOrDelivers() async {
        let r = Recorder(); r.onAcquire = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await r.run() }
        #expect(r.writes.isEmpty && r.stores == 0)
    }

    @Test func cancellationAfterUploadRemovesStagingWithoutInstalling() async {
        let r = Recorder()
        r.onWrite = { r.team = "different" }
        await #expect(throws: CloudCredentialTransfer.Failure.deliveryFailed) { try await r.run() }
        #expect(r.commands.last?.hasPrefix("rm -f -- ") == true)
    }

    @Test func providerOutputIsNeverAnErrorDiagnostic() async {
        struct SecretFailure: Error { let value: String }
        let r = Recorder(); r.onAcquire = { throw SecretFailure(value: String(decoding: Self.token, as: UTF8.self)) }
        await #expect(throws: CloudCredentialTransfer.Failure.deliveryFailed) { try await r.run() }
    }

    @Test func credentialFormatsAndCaptureAreProviderSpecific() throws {
        try CloudCredentialTransfer.validate(Self.token, provider: .claude)
        try CloudCredentialTransfer.validate(Self.codex, provider: .codex)
        #expect(throws: CloudCredentialTransfer.Failure.invalidCredential) { try CloudCredentialTransfer.validate(Self.codex, provider: .claude) }
        #expect(throws: CloudCredentialTransfer.Failure.invalidCredential) { try CloudCredentialTransfer.validate(Self.token, provider: .codex) }
        #expect(try CloudCredentialLogin.claudeToken(from: Data("\u{1b}[32mToken: ".utf8) + Self.token + Data("\nDone".utf8)) == Self.token)
        #expect(throws: CloudCredentialTransfer.Failure.invalidCredential) { try CloudCredentialLogin.claudeToken(from: Data("login failed".utf8)) }
        #expect(CloudCredentialLogin.name(provider: .claude, teamID: "t", userID: "a") != CloudCredentialLogin.name(provider: .claude, teamID: "t", userID: "b"))
    }

    @Test(arguments: [CloudCredentialTransfer.Provider.claude, .codex])
    func installerWritesPrivateRuntimeFilesAndOwnMode(provider: CloudCredentialTransfer.Provider) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home"), policy = directory.appendingPathComponent("policy")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: policy, withIntermediateDirectories: true)
        try Data("owner".utf8).write(to: policy.appendingPathComponent("vm-kind"))
        try Data().write(to: policy.appendingPathComponent("agent-auth.sh"))
        let source = directory.appendingPathComponent("payload")
        try (provider == .claude ? Self.token : Self.codex).write(to: source)
        let script = CloudCredentialInstaller.script
            .replacingOccurrences(of: "pathlib.Path('/etc/cmux')", with: "pathlib.Path(\(Self.pythonLiteral(policy.path)))")
            .replacingOccurrences(of: "pwd.getpwnam('cmux')", with: "pwd.getpwuid(os.geteuid())")
            .replacingOccurrences(of: "pathlib.Path(user.pw_dir)", with: "pathlib.Path(\(Self.pythonLiteral(home.path)))")
        let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, provider.rawValue, source.path], environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(10), clock: ContinuousClock())
        #expect(ran.status == 0)
        #expect(ran.stdout.isEmpty && ran.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let target = home.appendingPathComponent(provider == .claude ? ".claude/settings.json" : ".codex/auth.json")
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o600)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        if provider == .claude { #expect((object?["env"] as? [String: String])?["CLAUDE_CODE_OAUTH_TOKEN"] == String(decoding: Self.token, as: UTF8.self)) }
        else { #expect((object?["tokens"] as? [String: String])?["refresh_token"] == "refresh") }
        #expect(try String(contentsOf: home.appendingPathComponent(".config/cmux/agent-auth/\(provider.rawValue)"), encoding: .utf8) == "own\n")
    }

    static func pythonLiteral(_ value: String) -> String { CloudCredentialInstaller.quote(value) }
}
