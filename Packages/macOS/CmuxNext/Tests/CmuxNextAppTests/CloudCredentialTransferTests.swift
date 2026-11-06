import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import CmuxNextDaemon
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCredentialTransferTests {
    nonisolated static let token = Data("sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    nonisolated static let codex = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id"},"OPENAI_API_KEY":null}"#.utf8)

    @MainActor final class Recorder {
        /// Each sealed login sent to the machine.
        var installs: [Data] = []
        var logins = 0, stores = 0, pauses = 0
        var cached: Data?
        var owner = true
        var allowed = true
        /// The machine's answers in order; once used up, ``answer``.
        var answers: [CloudAPIClient.SealedDelivery] = []
        var answer: CloudAPIClient.SealedDelivery = .installed("claude")
        /// How long each send takes (a slow machine), and the transfer's wait budget.
        var installDelay: Duration?
        var budget: Duration?
        var team: String? = "team"
        var user: String? = "user"
        var onAcquire: (() throws -> Void)?
        var onInstall: (() -> Void)?
        var effects: CloudCredentialTransfer.Effects {
            .init(callerOwnsVM: { await MainActor.run { self.owner } },
                  stillAllowed: { await MainActor.run { self.allowed } },
                  pause: { await MainActor.run { self.pauses += 1 } },
                  install: { login in
                      if let delay = await MainActor.run(body: { self.installDelay }) { try? await Task.sleep(for: delay) }
                      return await MainActor.run {
                          self.installs.append(login); self.onInstall?()
                          return self.answers.isEmpty ? self.answer : self.answers.removeFirst()
                      }
                  },
                  load: { await MainActor.run { self.cached } },
                  acquire: { try await MainActor.run { self.logins += 1; try self.onAcquire?(); return CloudCredentialTransferTests.token } },
                  store: { value in await MainActor.run { self.stores += 1; self.cached = value } })
        }
        var transfer: CloudCredentialTransfer {
            var transfer = CloudCredentialTransfer(provider: .claude, machineID: "vm-one", teamID: "team", userID: "user", openTerminal: { _ in false })
            if let budget { transfer.guestBudget = budget }
            return transfer
        }
        func run(confirmed: Bool = true, refresh: Bool = false) async throws {
            try await transfer.run(currentTeamID: { self.team }, currentUserID: { self.user },
                                   confirmed: confirmed, refresh: refresh, effects: effects)
        }
    }

    static let notReady = CloudAPIClient.SealedDelivery.failed(code: "refused", refusal: "not-ready", retryable: true)

    /// A Release copy whose switch went off, or whose consent was taken back, during the confirm or
    /// the sign-in: the last check before the write stops it, and nothing reaches the machine.
    /// A Keychain that does not answer is not "no cached login": the start's record must tell them apart.
    @Test func anUnreadableCacheIsNotAMissingOne() async {
        #expect(await CloudCredentialTransfer.cachedLogin { Self.token } == .cached)
        #expect(await CloudCredentialTransfer.cachedLogin { nil } == .none)
        #expect(await CloudCredentialTransfer.cachedLogin { throw CloudCredentialTransfer.Failure.storeFailed } == .unreadable)
        #expect(await CloudCredentialTransfer.cachedLogin(provider: .codex, teamID: "team", userID: "user") == .none)
        // The start records which one it was.
        #expect(CloudCredentialTransfer.CachedLogin.cached.startOutcome == nil)
        #expect(CloudCredentialTransfer.CachedLogin.unreadable.startOutcome != CloudCredentialTransfer.CachedLogin.none.startOutcome)
    }

    @Test func aCopyTurnedOffBeforeTheWriteWritesNothing() async {
        let r = Recorder()
        r.cached = Self.token
        r.allowed = false
        await #expect(throws: CloudCredentialTransfer.Failure.copyTurnedOff) { try await r.run() }
        #expect(r.installs.isEmpty)
    }

    @Test func noConsentHasNoEffects() async {
        let r = Recorder()
        await #expect(throws: CloudCredentialTransfer.Failure.consentRequired) { try await r.run(confirmed: false) }
        #expect(r.installs.isEmpty && r.logins == 0 && r.stores == 0)
    }

    @Test func sharedMachineNeverReadsOrAcquiresCredentials() async {
        let r = Recorder(); r.owner = false
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.installs.isEmpty && r.logins == 0 && r.stores == 0)
    }

    /// Ownership lost during the login (the machine was handed off) stops the delivery.
    @Test func ownershipLostDuringLoginPreventsDelivery() async {
        let r = Recorder(); r.onAcquire = { r.owner = false }
        await #expect(throws: CloudCredentialTransfer.Failure.sharedMachine) { try await r.run() }
        #expect(r.installs.isEmpty)
    }

    /// The machine's daemon refuses a guest that is not the caller's owner guest, a custom endpoint and a bad
    /// login; each is its own failure, and none is sent again.
    @Test(arguments: ["not-owner-guest", "conflict", "invalid-credential", "replay"])
    func theMachinesRefusalIsTheFailure(refusal: String) async {
        let failure: CloudCredentialTransfer.Failure = switch refusal {
        case "not-owner-guest": .sharedMachine
        case "conflict": .incompatibleConfiguration
        case "invalid-credential": .invalidCredential
        default: .deliveryFailed
        }
        let r = Recorder(); r.cached = Self.token
        r.answer = .failed(code: "refused", refusal: refusal, retryable: false)
        await #expect(throws: failure) { try await r.run() }
        #expect(r.installs.count == 1 && r.pauses == 0)
    }

    /// A machine without `secrets-v1` (an older image) is still setting up as far as the copy goes; a dial that
    /// fails is a failed delivery.
    @Test func aMachineWithoutSecretsV1OrACarrierIsNotDeliveredTo() async {
        let r = Recorder(); r.cached = Self.token
        r.answer = .failed(code: "unsupported", refusal: nil, retryable: false)
        await #expect(throws: CloudCredentialTransfer.Failure.machineNotReady) { try await r.run() }
        r.answer = .failed(code: "parked_timeout", refusal: nil, retryable: true)
        await #expect(throws: CloudCredentialTransfer.Failure.deliveryFailed) { try await r.run() }
    }

    /// The creator allowance rides the request; the machine's daemon decides it (a DEV daemon only).
    @Test func theCreatorAllowanceIsOnlyAsked() {
        let plain = CloudCredentialTransfer(provider: .claude, machineID: "vm", teamID: "t", userID: "u", openTerminal: { _ in false })
        let creator = CloudCredentialTransfer(provider: .claude, machineID: "vm", teamID: "t", userID: "u", allowsCreatorTeamGuest: true,
                                              openTerminal: { _ in false })
        #expect(!plain.allowsCreatorTeamGuest && creator.allowsCreatorTeamGuest)
        #expect(plain.restartGuestCheck.contains("owner)") && creator.restartGuestCheck.contains("owner|team)"))
    }

    /// A copy right after the machine is created: the guest's cmux-host writes /etc/cmux/vm-kind only once it
    /// binds, so the daemon answers `not-ready` at first. The copy sends again until it binds.
    @Test func aCopyRightAfterCreateWaitsForTheGuestsBind() async throws {
        let r = Recorder(); r.cached = Self.token; r.answers = [Self.notReady, Self.notReady]
        try await r.run()
        #expect(r.installs.count == 3 && r.pauses == 2)
    }

    /// A guest that never records its kind is not taken for a shared machine: the copy stops after its
    /// budget, saying the machine is still setting up.
    @Test func aGuestThatNeverBindsStopsAfterTheBudget() async {
        let r = Recorder(); r.cached = Self.token; r.answer = Self.notReady
        await #expect(throws: CloudCredentialTransfer.Failure.machineNotReady) { try await r.run() }
        #expect(r.pauses == CloudCredentialTransfer.guestCheckTries - 1 && r.installs.count == CloudCredentialTransfer.guestCheckTries)
    }

    /// The budget holds in wall time: a machine whose every send is slow is cut off at the budget, not after the
    /// send in flight finishes (a 2 s send against 200 ms).
    @Test func aSlowMachineIsCutOffAtTheBudget() async {
        let r = Recorder(); r.cached = Self.token; r.answer = Self.notReady
        r.installDelay = .seconds(2); r.budget = .milliseconds(200)
        let started = ContinuousClock.now
        await #expect(throws: CloudCredentialTransfer.Failure.machineNotReady) { try await r.run() }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func firstTransferStoresThenDeliversAndRepeatReusesScopedCache() async throws {
        let r = Recorder()
        try await r.run(); try await r.run()
        #expect(r.logins == 1 && r.stores == 1 && r.installs.count == 2)
        #expect(r.installs.allSatisfy { $0 == Self.token })
        try await r.run(refresh: true)
        #expect(r.logins == 2 && r.stores == 2)
    }

    @Test(arguments: [true, false])
    func accountOrTeamSwitchDuringLoginPreventsStoreAndDelivery(changeUser: Bool) async {
        let r = Recorder()
        r.onAcquire = { if changeUser { r.user = "other" } else { r.team = "other" } }
        await #expect(throws: CloudCredentialTransfer.Failure.scopeChanged) { try await r.run() }
        #expect(r.installs.isEmpty && r.stores == 0)
    }

    @Test func cancelledLoginNeverStoresOrDelivers() async {
        let r = Recorder(); r.onAcquire = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await r.run() }
        #expect(r.installs.isEmpty && r.stores == 0)
    }

    /// A scope change while the machine is not ready yet stops the retries.
    @Test func aScopeChangeBetweenSendsStopsTheCopy() async {
        let r = Recorder(); r.cached = Self.token; r.answer = Self.notReady
        r.onInstall = { r.team = "different" }
        await #expect(throws: CloudCredentialTransfer.Failure.scopeChanged) { try await r.run() }
        #expect(r.installs.count == 1)
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
}
