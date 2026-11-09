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

    public init(auth: CloudAuth, cli: CloudMoveCLI, platform: URL, api: CloudAPIClient, installIdentity: MacInstallIdentity,
                gate: CloudLoginCopyGate, dogfood: Bool, logger: Logger) {
        self.auth = auth; self.cli = cli; self.platform = platform; self.api = api; self.installIdentity = installIdentity
        self.gate = gate; self.dogfood = dogfood; self.logger = logger
    }

    /// Fires the warm; the caller never awaits it. Rust decides everything around it: the team (from the active team),
    /// the throttle, the copy target (the only ownership check) and the copy in flight a start waits on, which this
    /// reports finished, or abandoned when the account or team switched mid-copy (Rust then answers it again).
    /// `claimed`: a reserve's or a claim's answer named this machine, so no warm goes out: Rust answers the copy onto
    /// that exact machine unless one onto it is in flight or given, and a start onto it waits on that copy.
    /// Off unless `cmux.cloud.copyLoginOnClaim` is on (``CloudMoveCLI/copiesLoginOnClaim(_:)``).
    public func start(claimed: String? = nil) {
        guard let userID = auth.user?.id, claimed == nil || CloudMoveCLI.copiesLoginOnClaim(.standard) else { return }
        let teamID = auth.teamID
        // task-owner: none; one bounded warm, its calls' own timeouts end it, and Rust's lock and throttle answer repeats.
        Task { @MainActor [self] in
            guard let token = try? await auth.tokens().access, let install = try? await installIdentity.installToken(),
                  let copy = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, claimed: claimed) else { return }
            let still: @MainActor @Sendable () async throws -> Bool = { [auth] in auth.user?.id == userID && auth.teamID == teamID }
            let installed = await copyLogin(onto: copy.machineID, userID: userID, teamID: teamID, still: still)
            let kept = installed ? true : (try? await still()) == true
            let end: CloudMoveCLI.SpareWarmEnd = kept ? .finished(copy.machineID) : .abandoned(copy.machineID)
            _ = await cli.startChatWarmSpare(platform: platform, account: userID, access: token, install: install, end: end)
        }
    }

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
            try await decision.readMachine(exec: { (try? await pinned.exec(machineID, command: $0, timeoutMs: 20_000))?.stdout }, pause: CloudCredentialTransfer.guestCheckPause) {
                await CloudMachineLogin.read(on: pinned, machineID: machineID, teamID: teamID, userID: userID, otherTeams: otherTeams)
            }
            guard decision.verdict.transferProvider == .claude, decision.verdict.step == .install else { return false }
            if let outcome = try await CloudCredentialTransfer.CachedLogin.startOutcome({
                await CloudCredentialTransfer.cachedLogin(provider: .claude, teamID: teamID, userID: userID, otherTeams: otherTeams)
            }) {
                decision.outcome = outcome
                return false
            }
            guard auth.user?.id == userID, auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: .claude, machineID: machineID, teamID: teamID, userID: userID, otherTeams: otherTeams, openTerminal: { _ in false })
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
