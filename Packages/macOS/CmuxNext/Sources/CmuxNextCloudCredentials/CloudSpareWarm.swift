public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation

/// Leo, Cloud V0 item 1: "harness login attached in advance". On the person's intent (the composer picks Cloud, the
/// app comes to the front signed in, a reserve or a claim names a machine) the app tells the daemon, one
/// `cloud-spare-warm` command, and Rust does the rest (cmux-tui `link/start_chat_cli/spare_warm/daemon.rs`): whether to
/// warm, the warm or claim call, and the headless copy of the person's Claude login onto the machine. The chat that
/// claims the spare then finds "machine login cached".
///
/// Leo, 2026-11-10, about the Swift warm this replaces: "Why is this even in Swift anyways mang". It spawned the CLI and
/// wrote its stdin from the main actor on every activation (the NIGHTLY freeze). This sends only what the app holds
/// (its tokens) and keeps (its defaults and cmux.json), and waits on nothing.
@MainActor public struct CloudSpareWarm {
    let auth: CloudAuth, installIdentity: MacInstallIdentity, connection: DaemonConnection
    /// The platform origin the warm calls, and the cmux API the copy's machine routes and remote switch call.
    let platform: URL, api: URL
    /// DEV and dogfood builds, and the person's one-time Release consent from cmux.json now (nil: never asked) with whether
    /// the daemon link is up; the daemon is told the consent on every change and every reconnect, so a copy in flight reads
    /// it right before its write.
    let dogfood: Bool, consent: @MainActor @Sendable () -> CloudLoginCopyConsentNow
    /// The app's one registry of claims Rust has not answered yet: a start onto a claimed machine waits on it first.
    let claims: CloudClaimedCopyRegistrations

    public init(auth: CloudAuth, installIdentity: MacInstallIdentity, connection: DaemonConnection, platform: URL, api: URL,
                dogfood: Bool, consent: @escaping @MainActor @Sendable () -> CloudLoginCopyConsentNow, claims: CloudClaimedCopyRegistrations) {
        (self.auth, self.installIdentity, self.connection, self.platform, self.api) = (auth, installIdentity, connection, platform, api)
        (self.dogfood, self.consent, self.claims) = (dogfood, consent, claims)
    }

    /// Sends the intent; the caller never awaits it. `claimed`: a reserve's or a claim's answer named this machine, so
    /// Rust warms nothing and answers the copy onto it (on unless `cmux.cloud.copyLoginOnClaim` is NO). A claim stays
    /// pending in `claims` until the daemon's ledger answers it, so a start onto that machine never asks `wait-copy` first.
    public func start(claimed: String? = nil) {
        guard let userID = auth.user?.id, claimed == nil || CloudMoveCLI.copiesLoginOnClaim(.standard) else { return }
        let team = auth.teamID, teams = auth.teams.map(\.id)
        let setting = CloudCredentialTransfer.passHarnessLoginSetting(.standard)
        let stored = CloudHarnessLoginChoices().load(userID: userID)?.rawValue
        claims.followConsent(on: connection, consent)
        let (auth, installIdentity, connection, platform, api, dogfood, consent) = (auth, installIdentity, connection, platform, api, dogfood, consent().consent)
        let generation = claims.consentGeneration() // numbered now, as it is read, before any await
        let send: @MainActor @Sendable () async -> Void = {
            guard let access = try? await auth.tokens().access, let install = try? await installIdentity.installToken() else { return }
            // The consent first, on this link, so the daemon holds the latest one before it starts any copy (a reconnect
            // the follower missed included).
            _ = try? await connection.request(CloudSpareWarmConsentRequest(consent: consent, generation: generation), timeout: .seconds(5))
            let request = CloudSpareWarmRequest(platform: platform.absoluteString, api: api.absoluteString, accessToken: access,
                                                installToken: install, account: userID, claimed: claimed, team: team, loginTeams: teams,
                                                dogfood: dogfood, setting: setting, storedChoice: stored, consent: consent)
            // The ledger answers after the platform's warm call (90 s at most); the copy goes on in the daemon after it.
            _ = try? await connection.request(request, timeout: .seconds(120))
        }
        if let claimed {
            _ = claims.register(claimed, send)
        } else {
            // task-owner: none; one daemon request bounded by its timeout, and Rust's lock and throttle answer repeats.
            Task { @MainActor in await send() }
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
    /// the daemon's copy ends installed); then the start records ``warmReceipt`` and reads and passes no login
    /// of its own (Leo, 2026-11-10: "if they're logged in why do we need to re-check their login after the critical path").
    /// Never for a `--login` word, which decides for itself; no harness named is Claude, as the rules read it.
    /// `cli` runs on the daemon's state root (``CloudMoveCLI/stateDirectory``), where the daemon's warm keeps the receipt.
    mutating func takeWarmReceipt(cli: CloudMoveCLI?, machine: String, userID: String?, ask: CloudHarnessLoginAsk) async -> Bool {
        guard ask.requested == nil, let cli, let userID else { return false }
        let provider = harness.flatMap { $0.isEmpty ? nil : $0 } ?? CloudCredentialTransfer.Provider.claude.rawValue
        guard await cli.startChatLoginReceipt(machine: machine, account: userID, provider: provider) else { return false }
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
