@testable import CmuxNextCloudCredentials
import CmuxNextDaemon
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCredentialTransferTests {
    nonisolated static let token = Data("sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    nonisolated static let codex = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id"},"OPENAI_API_KEY":null}"#.utf8)

    @MainActor final class Recorder {
        var commands: [String] = []
        var writes: [(String, Data)] = []
        var logins = 0, stores = 0
        var cached: Data?
        var owner = true
        var preflight: Int = 0
        var team: String? = "team"
        var user: String? = "user"
        var onAcquire: (() throws -> Void)?
        var onWrite: (() -> Void)?
        var effects: CloudCredentialTransfer.Effects {
            .init(callerOwnsVM: { await MainActor.run { self.owner } },
                  exec: { command in await MainActor.run { self.commands.append(command); return self.preflight } },
                  write: { path, data in await MainActor.run { self.writes.append((path, data)); self.onWrite?() } },
                  load: { await MainActor.run { self.cached } },
                  acquire: { try await MainActor.run { self.logins += 1; try self.onAcquire?(); return CloudCredentialTransferTests.token } },
                  store: { value in await MainActor.run { self.stores += 1; self.cached = value } })
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
        #expect(r.commands.isEmpty && r.writes.isEmpty && r.logins == 0 && r.stores == 0)
    }

    /// The caller's ownership is the platform's answer; a machine without the image's launchers
    /// still never receives a login.
    @Test func ownedMachineWithoutLaunchersNeverReadsOrAcquiresCredentials() async {
        let r = Recorder(); r.preflight = 1
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.writes.isEmpty && r.logins == 0 && r.stores == 0)
    }

    /// Ownership lost during the login (the machine was handed off) stops the delivery.
    @Test func ownershipLostDuringLoginPreventsDelivery() async {
        let r = Recorder(); r.onAcquire = { r.owner = false }
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.writes.isEmpty)
    }

    /// The caller's ownership answer is required, and the guest must still be an owner machine.
    @Test func theOwnerGuestStaysRequired() {
        #expect(CloudCredentialInstaller.preflight.contains("/etc/cmux/vm-kind"))
        #expect(CloudCredentialInstaller.script.contains("'vm-kind'"))
    }

    /// The DEV creator allowance swaps only the guest-kind line: the caller's owner answer, the launchers
    /// check and the work-user checks stay, and the installer accepts a team guest only when asked.
    @Test func theCreatorAllowanceAcceptsATeamGuestOnlyWhenAsked() {
        let plain = CloudCredentialTransfer(provider: .claude, machineID: "vm", teamID: "t", userID: "u", openTerminal: { _ in false })
        let creator = CloudCredentialTransfer(provider: .claude, machineID: "vm", teamID: "t", userID: "u", allowsCreatorTeamGuest: true,
                                              openTerminal: { _ in false })
        #expect(plain.preflight == CloudCredentialInstaller.preflight)
        #expect(creator.preflight == CloudCredentialInstaller.creatorTeamPreflight)
        #expect(CloudCredentialInstaller.creatorTeamPreflight.contains("owner|team"))
        #expect(CloudCredentialInstaller.creatorTeamPreflight.contains("/etc/cmux/agent-auth.sh"))
        #expect(CloudCredentialInstaller.command(provider: .claude, payloadPath: "/p").contains("'/p' owner <<"))
        #expect(CloudCredentialInstaller.command(provider: .claude, payloadPath: "/p", creatorTeamGuest: true).contains("'/p' owner,team <<"))
    }

    /// Without the allowance, a caller-owned machine whose guest is a team one is refused before any login.
    @Test func ownerAnswerOnATeamGuestStillNeedsTheAllowance() async {
        let r = Recorder(); r.preflight = 1
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.commands == [CloudCredentialInstaller.preflight] && r.logins == 0)
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

    @Test func actualTaskCancellationCleansStagingFromAnUncancelledTask() async {
        let r = Recorder()
        var effects = r.effects
        effects.write = { path, data in
            await MainActor.run { r.writes.append((path, data)) }
            withUnsafeCurrentTask { $0?.cancel() }
        }
        effects.exec = { command in
            // Real CloudAPIClient calls reject cancellation before starting their request.
            try Task.checkCancellation()
            await MainActor.run { r.commands.append(command) }
            return 0
        }
        let task = Task { @MainActor in
            try await r.transfer.run(currentTeamID: { r.team }, currentUserID: { r.user },
                                     confirmed: true, effects: effects)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(r.writes.count == 1)
        #expect(r.commands.last?.hasPrefix("rm -f -- ") == true)
        #expect(!r.commands.contains { $0.contains("CMUX_CREDENTIAL_INSTALL") })
    }

    @Test func claudeLoginCapturesTokenWithoutPrintingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("login test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '\\033[32mhttps://claude.ai/oauth/authorize?code=abc\\033[0m\\n' >&2\nprintf '%s\\n' '\(String(decoding: Self.token, as: UTF8.self))' >&2\nprintf 'private diagnostic\\n' >&2\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", CloudCredentialLogin.loginScript(provider: .claude, directory: directory)],
            environment: ["PATH": directory.path + ":/usr/bin:/bin"], timeout: .seconds(10), clock: ContinuousClock())
        #expect(ran.status == 0)
        #expect(!ran.stdout.isEmpty && !String(decoding: ran.stdout, as: UTF8.self).contains(String(decoding: Self.token, as: UTF8.self)))
        #expect(!String(decoding: ran.stdout, as: UTF8.self).contains("private diagnostic"))
        #expect(ran.stderr.isEmpty)
        #expect(String(decoding: ran.stdout, as: UTF8.self).contains("https://claude.ai/oauth/authorize?code=abc"))
        #expect(String(decoding: ran.stdout, as: UTF8.self).contains("one-time code"))
        #expect(try CloudCredentialLogin.claudeToken(from: Data(contentsOf: directory.appendingPathComponent("output"))) == Self.token)
        #expect(try String(contentsOf: directory.appendingPathComponent("status"), encoding: .utf8) == "0")
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

    /// The cached login is read back as `security find-generic-password -w` prints what `cloud secret set`
    /// stored: the envelope on one line. Anything else is no login (the start asks once), never a hang.
    @Test func cachedLoginEnvelopeReadsAsSecurityPrintsIt() {
        let envelope = #"{"created":1767225600,"credential":"\#(Self.token.base64EncodedString())"}"#
        #expect(CloudCredentialLogin.credential(envelope: Data((envelope + "\n").utf8)) == Self.token)
        #expect(CloudCredentialLogin.credential(envelope: Data(envelope.utf8)) == Self.token)
        #expect(CloudCredentialLogin.credential(envelope: Data(#"{"created":0,"credential":"eA=="}"#.utf8)) == nil)
        #expect(CloudCredentialLogin.credential(envelope: Data("not json\n".utf8)) == nil)
        #expect(CloudCredentialLogin.service == "cmux-cloud-secret")
        #expect(CloudCredentialLogin.readTimeout <= .seconds(30))
    }

    @Test(arguments: [CloudCredentialTransfer.Provider.claude, .codex], [false, true])
    func installerAcceptsShippedPlaneButRejectsCustomEndpoints(provider: CloudCredentialTransfer.Provider, custom: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home"), policy = directory.appendingPathComponent("policy")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: policy, withIntermediateDirectories: true)
        // A team guest is refused first: teammates share its Unix user.
        try Data("team".utf8).write(to: policy.appendingPathComponent("vm-kind"))
        let root = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let auth = try String(contentsOf: root.appendingPathComponent("web/services/vms/images/devbox/agent-auth.sh"), encoding: .utf8)
            .replacingOccurrences(of: "/etc/cmux", with: policy.path)
        try Data(auth.utf8).write(to: policy.appendingPathComponent("agent-auth.sh"))
        let source = directory.appendingPathComponent("payload")
        try (provider == .claude ? Self.token : Self.codex).write(to: source)
        func installer() -> String {
            CloudCredentialInstaller.command(provider: provider, payloadPath: source.path)
            .replacingOccurrences(of: "/etc/cmux/agent-auth.sh", with: policy.appendingPathComponent("agent-auth.sh").path)
            .replacingOccurrences(of: "pathlib.Path('/etc/cmux')", with: "pathlib.Path(\(Self.pythonLiteral(policy.path)))")
            .replacingOccurrences(of: "pwd.getpwnam('cmux')", with: "pwd.getpwuid(os.geteuid())")
            .replacingOccurrences(of: "pathlib.Path(user.pw_dir)", with: "pathlib.Path(\(Self.pythonLiteral(home.path)))")
        }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path,
            "CMUX_CODEROUTER_URL": "https://plane.example", "OPENAI_BASE_URL": custom ? "https://custom.example/v1" : "https://plane.example/v1",
            "OPENAI_API_KEY": "cmux-vm-edge-placeholder", "ANTHROPIC_BASE_URL": "https://plane.example",
            "ANTHROPIC_API_KEY": "cmux-vm-edge-placeholder"]
        // The team guest is refused and gets no login.
        let refused = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", installer()], environment: environment,
            timeout: .seconds(10), clock: ContinuousClock())
        #expect(refused.status != 0)
        // The DEV creator allowance installs it there (custom endpoints are still refused).
        let teamHome = directory.appendingPathComponent("team-home")
        try FileManager.default.createDirectory(at: teamHome, withIntermediateDirectories: true)
        let creator = CloudCredentialInstaller.command(provider: provider, payloadPath: source.path, creatorTeamGuest: true)
            .replacingOccurrences(of: "/etc/cmux/agent-auth.sh", with: policy.appendingPathComponent("agent-auth.sh").path)
            .replacingOccurrences(of: "pathlib.Path('/etc/cmux')", with: "pathlib.Path(\(Self.pythonLiteral(policy.path)))")
            .replacingOccurrences(of: "pwd.getpwnam('cmux')", with: "pwd.getpwuid(os.geteuid())")
            .replacingOccurrences(of: "pathlib.Path(user.pw_dir)", with: "pathlib.Path(\(Self.pythonLiteral(teamHome.path)))")
        let allowed = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", creator], environment: environment, timeout: .seconds(10), clock: ContinuousClock())
        #expect((allowed.status == 0) == !custom)
        #expect(FileManager.default.fileExists(atPath: teamHome.appendingPathComponent(".config/cmux/agent-auth/\(provider.rawValue)").path) == !custom)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/cmux/agent-auth/\(provider.rawValue)").path))
        try (provider == .claude ? Self.token : Self.codex).write(to: source)
        try Data("owner".utf8).write(to: policy.appendingPathComponent("vm-kind"))
        let ran = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", installer()], environment: environment,
            timeout: .seconds(10), clock: ContinuousClock())
        #expect(ran.stdout.isEmpty && ran.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let target = home.appendingPathComponent(provider == .claude ? ".claude/settings.json" : ".codex/auth.json")
        if custom {
            #expect(ran.status != 0)
            #expect(!FileManager.default.fileExists(atPath: target.path))
            return
        }
        #expect(ran.status == 0)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o600)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        if provider == .claude { #expect((object?["env"] as? [String: String])?["CLAUDE_CODE_OAUTH_TOKEN"] == String(decoding: Self.token, as: UTF8.self)) }
        else { #expect((object?["tokens"] as? [String: String])?["refresh_token"] == "refresh") }
        #expect(try String(contentsOf: home.appendingPathComponent(".config/cmux/agent-auth/\(provider.rawValue)"), encoding: .utf8) == "own\n")
        if provider == .claude {
            let credentials = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))) as? [String: Any]
            #expect(credentials?["claudeAiOauth"] != nil)
        }
        let resolve = ". \(CloudCredentialInstaller.quote(policy.appendingPathComponent("agent-auth.sh").path)); cmux_agent_auth_resolve \(provider.rawValue); printf '%s %s' \"$cmux_agent_auth_mode\" \"$cmux_agent_auth_reason\""
        let own = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", resolve],
            environment: environment, timeout: .seconds(10), clock: ContinuousClock())
        #expect(String(decoding: own.stdout, as: UTF8.self) == "own chosen")
        try Data("team".utf8).write(to: policy.appendingPathComponent("vm-kind"))
        let shared = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", resolve],
            environment: environment, timeout: .seconds(10), clock: ContinuousClock())
        #expect(String(decoding: shared.stdout, as: UTF8.self) == "team shared-machine")
    }

    static func pythonLiteral(_ value: String) -> String { CloudCredentialInstaller.quote(value) }
}
