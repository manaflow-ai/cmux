public import CmuxNextCloud
public import Foundation
public import os

/// Leo, Cloud V0 item 1: "harness login attached in advance". On the person's intent (the composer picks Cloud, or the
/// app comes to the front signed in) Rust warms their paused spare (`cmux link start-chat warm-spare`, which also picks
/// the team, the owned copy target and how often), and this copies their Claude login onto it, headless, with the
/// start's own transfer. The chat that claims the spare then finds "machine login cached".
@MainActor public final class CloudSpareWarm {
    /// The warm's harness login line: the probe ties a later "machine login cached" to it (cmuxterm-hq#7725).
    public static let step = "cloud warm spare"

    let auth: CloudAuth, cli: CloudMoveCLI, platform: URL, api: CloudAPIClient, installIdentity: MacInstallIdentity
    let gate: CloudLoginCopyGate, dogfood: Bool, logger: Logger
    /// The app's one registry of claims Rust has not answered yet: a start onto a claimed machine waits on it first.
    let claims: CloudClaimedCopyRegistrations

    public init(auth: CloudAuth, cli: CloudMoveCLI, platform: URL, api: CloudAPIClient, installIdentity: MacInstallIdentity,
                gate: CloudLoginCopyGate, dogfood: Bool, logger: Logger, claims: CloudClaimedCopyRegistrations) {
        self.auth = auth; self.cli = cli; self.platform = platform; self.api = api; self.installIdentity = installIdentity
        self.gate = gate; self.dogfood = dogfood; self.logger = logger; self.claims = claims
    }

    /// Fires the warm; the caller never awaits it. Rust decides everything around it: the team (from the active team),
    /// the throttle, the copy target (the only ownership check) and the copy in flight a start waits on, which this
    /// reports finished, or abandoned when the account or team switched mid-copy (Rust then answers it again).
    /// `claimed`: a reserve's or a claim's answer named this machine, so no warm goes out: Rust answers the copy onto
    /// that exact machine unless one onto it is in flight or given, and a start onto it waits on that copy.
    /// On unless `cmux.cloud.copyLoginOnClaim` is NO (``CloudMoveCLI/copiesLoginOnClaim(_:)``). A claim's registration
    /// with Rust is pending in `claims` until Rust answers, so a start onto that machine never asks `wait-copy` first.
    public func start(claimed: String? = nil) {
        guard let userID = auth.user?.id, claimed == nil || CloudMoveCLI.copiesLoginOnClaim(.standard) else { return }
        let teamID = auth.teamID
        let ask: @MainActor @Sendable () async -> Asked? = { [self] in
            guard let token = try? await auth.tokens().access, let install = try? await installIdentity.installToken(),
                  let copy = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, claimed: claimed) else { return nil }
            return Asked(copy: copy, token: token, install: install)
        }
        let answer = claimed.map { claims.register($0, ask) }
        // task-owner: none; one bounded warm, its calls' own timeouts end it, and Rust's lock and throttle answer repeats.
        Task { @MainActor [self] in
            let asked: Asked?
            if let answer { asked = await answer.value } else { asked = await ask() }
            guard let asked else { return }
            let (copy, token, install) = (asked.copy, asked.token, asked.install)
            let still: @MainActor @Sendable () async throws -> Bool = { [auth] in auth.user?.id == userID && auth.teamID == teamID }
            let installed = await copyLogin(onto: copy.machineID, userID: userID, teamID: teamID, still: still)
            let kept = installed ? true : (try? await still()) == true
            // An installed copy is the receipt a start onto this machine takes instead of checking the login again.
            let end: CloudMoveCLI.SpareWarmEnd = installed ? .installed(copy.machineID) : kept ? .finished(copy.machineID) : .abandoned(copy.machineID)
            _ = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, end: end)
        }
    }

    /// Rust's answer to a warm or a claim that hands the App a copy, and the tokens that report its end.
    struct Asked: Sendable { var copy: CloudMoveCLI.SpareWarm, token: String, install: String }

    /// The start's Claude copy with no prompt: only a verdict that installs as is (a cached login, consent given) copies;
    /// never as a team guest. Answers whether a login was installed; never throws.
    func copyLogin(onto machineID: String, userID: String, teamID: String?, still: @escaping @MainActor @Sendable () async throws -> Bool) async -> Bool {
        let otherTeams = auth.loginScopes, pinned = api.pinningTeam(teamID)
        var decision = CloudHarnessLoginDecision(dogfood: dogfood, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard), harness: "claude", signedIn: true)
        await gate.read(into: &decision)
        CloudHarnessLoginAsk(headless: true).apply(to: &decision, userID: userID)
        defer { logger.info("\(Self.step, privacy: .public): harness login \(decision.summary, privacy: .public)") }
        do {
            guard decision.verdict.gate, decision.verdict.transferProvider == .claude else { return false }
            decision.callerOwns = try await still()
            try await decision.readMachine(on: pinned, machineID: machineID, teamID: teamID, userID: userID, otherTeams: otherTeams)
            guard decision.verdict.transferProvider == .claude, decision.verdict.step == .install else { return false }
            if let outcome = try await CloudCredentialTransfer.CachedLogin.startOutcome({
                await CloudCredentialTransfer.cachedLogin(provider: .claude, teamID: teamID, userID: userID, otherTeams: otherTeams)
            }) {
                decision.outcome = outcome
                return false
            }
            guard auth.user?.id == userID, auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: .claude, machineID: machineID, teamID: teamID, userID: userID, otherTeams: otherTeams,
                                                   guestCheckedAt: decision.guestCheckedAt, openTerminal: { _ in false })
            try await transfer.run(api: api, currentTeamID: { [auth] in auth.teamID }, currentUserID: { [auth] in auth.user?.id },
                                   confirmed: true, callerOwnsVM: still, stillAllowed: gate.stillAllowed)
            decision.outcome = "installed"
            return true
        } catch {
            decision.outcome = CloudHarnessLoginDecision.loginOutcome(error, cancelled: Task.isCancelled)
            return false
        }
    }
}

public extension CloudAuth {
    /// Every scope a person's cached Claude login may sit under: each of their teams, then their personal scope. One login per person, whichever team is selected.
    var loginScopes: [String?] { teams.map { Optional($0.id) } + [nil] }
}

public extension CloudHarnessLoginDecision {
    /// The start record's outcome when a spare warm's installed copy on the start's machine stood in for the login check.
    nonisolated static let warmReceipt = "warm receipt"

    /// Whether a spare warm already installed `userID`'s login on `machine` before Send (Rust's `loginReceipt`, kept when
    /// ``CloudSpareWarm`` reports its copy installed); then the start records ``warmReceipt`` and reads and passes no login
    /// of its own (Leo, 2026-11-10: "if they're logged in why do we need to re-check their login after the critical path").
    /// Never for a `--login` word, which decides for itself; no harness named is Claude, as the rules read it.
    mutating func takeWarmReceipt(cli binary: URL?, machine: String, userID: String?, ask: CloudHarnessLoginAsk) async -> Bool {
        guard ask.requested == nil, let binary, let userID else { return false }
        let provider = harness.flatMap { $0.isEmpty ? nil : $0 } ?? CloudCredentialTransfer.Provider.claude.rawValue
        guard await CloudMoveCLI(binary: binary).startChatLoginReceipt(machine: machine, account: userID, provider: provider) else { return false }
        outcome = Self.warmReceipt
        return true
    }

    /// A login cancelled with its start (its copy failed before `run` awaited it) is `cancelled`, never "failed: CancellationError" (run 42157718918).
    nonisolated static let loginCancelled = "cancelled"
    /// The start record's outcome when the copy failed, before its fixed text.
    nonisolated static let loginFailed = "failed: "
    /// The start record's outcome when the person said no to the copy.
    nonisolated static let loginDeclined = "declined"
    /// The outcomes when this Mac held no login to give: the machine signs in with its chat's Sign in to Claude card.
    nonisolated static let signInOnMachine: Set<String?> = [CloudCredentialTransfer.CachedLogin.none.startOutcome, CloudCredentialTransfer.CachedLogin.unreadable.startOutcome]

    /// What a login that threw records: `cancelled` when its start cancelled it, else the transfer's fixed text, never provider output.
    nonisolated static func loginOutcome(_ error: any Error, cancelled: Bool) -> String {
        cancelled || error is CancellationError ? loginCancelled : loginFailed + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
    }
}
