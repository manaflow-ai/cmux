import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// A `cloud.startChat` chat's harness login, before its first prompt (Leo, 2026-10-31: "A TOKEN GETS PASSED"). On a
/// machine the signed-in person owns (the attach answer's `vmKind == "owner"`, which a team machine's creator gets too,
/// #28788), Claude gets the person's own `claude setup-token` login through ``CloudCredentialTransfer``: silently when
/// cmux already holds that login for this account, else after one confirm that runs `setup-token` once in a visible
/// local terminal; later machines of the account get it with no prompt. Codex gets the Mac's broker (cmux#33489).
///
/// DEV and dogfood builds pass it as before. A Release build passes it only on Leo's three conditions
/// (``CloudLoginCopyGate``); otherwise the machine's chat offers its own one-click "Sign in to Claude".
///
/// The decision's rules are Rust's (``CloudHarnessLoginDecision``, cmux-cloud-start-core); this
/// extension reads the machine and the account and acts on it.
///
/// Never blocks the chat: a machine that is not the person's, a cancelled confirm or a failed install
/// opens the chat anyway, and its turn card still offers recovery (#26148).
extension CloudStartChat {
    /// Every scope a person's cached Claude login may sit under: each of their teams, then their personal scope. One login per person, whichever team is selected.
    @MainActor static func loginScopes(_ cloud: CloudService) -> [String?] { cloud.auth.teams.map { Optional($0.id) } + [nil] }
    /// A login cancelled with its start (its copy failed before `run` awaited it) is `cancelled`, never "failed: CancellationError" (run 42157718918).
    nonisolated static let loginCancelled = "cancelled"
    /// What a login that threw records: `cancelled` when its start cancelled it, else the transfer's fixed text, never provider output.
    nonisolated static func loginOutcome(_ error: any Error, cancelled: Bool) -> String {
        cancelled || error is CancellationError ? loginCancelled : loginFailed + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
    }

    /// Gives the start's machine the person's Claude or Codex login when this build passes it. Returns
    /// whether a login was installed; never throws. `cmux cloud start-session` passes it the same way, with no Codex prompt.
    /// Its questions show where ``asker`` shows them: the start's card for a composer start, else a dialog in the active window.
    func passHarnessLogin(harness: String?, machine: CloudMachineSession, codexPrompt: Bool = true, ask: CloudHarnessLoginAsk = .init()) async -> Bool {
        let cloud = services.cloud
        return await passHarnessLogin(harness: harness, target: .init(machineID: machine.machineID, title: machine.machine.title, step: "cloud start chat", ownerOnly: false,
            callerOwns: { [machineID = machine.machineID] in try await cloud.callerOwnsVM(machineID) }, record: { machine.harnessLogin = $0 }), codexPrompt: codexPrompt, ask: ask)
    }

    /// The machine a login goes to: a start's session, or a warm spare that has none yet (CloudStartChat+WarmSpare).
    struct LoginTarget {
        let machineID: String, title: String, step: String
        /// A copy nobody asked for (the warm's): only onto a machine the person owns, never as a team guest.
        let ownerOnly: Bool
        let callerOwns: @MainActor @Sendable () async throws -> Bool
        let record: @MainActor (CloudHarnessLoginDecision) -> Void
    }

    func passHarnessLogin(harness: String?, target: LoginTarget, codexPrompt: Bool = true, ask: CloudHarnessLoginAsk = .init()) async -> Bool {
        let cloud = services.cloud, userID = cloud.auth.user?.id, asker = self.asker ?? .window(services)
        let teamID = cloud.auth.teamID, machineID = target.machineID, api = cloud.machineAPI.pinningTeam(teamID)
        // A Claude start waits for a warm copy in flight (CloudStartChat+WarmSpare) instead of racing it on the same
        // machine; the start stays bound to the account and team it began in.
        if !target.ownerOnly, harness?.hasPrefix("claude") ?? true, let warm = cloud.spareWarm {
            await warm.value
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
        }
        let otherTeams = Self.loginScopes(cloud) // the person's cached login under any of their teams, or their personal scope: one per person
        var decision = CloudHarnessLoginDecision(dogfood: DevTools.isEnabled, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: userID != nil)
        let gate = Self.loginCopyGate(services, asker: asker)
        await gate.read(into: &decision)
        ask.apply(to: &decision, userID: userID) // `--login`, the kept choice, and whether a prompt may show
        // Never silent (CloudHarnessLoginDecision): the reason goes to the log and the machine's `cloud.machines` row.
        defer { target.record(decision); cloud.logger.info("\(target.step, privacy: .public): harness login \(decision.summary, privacy: .public)") }
        do {
            var verdict = decision.verdict // One FFI answer per step (cmux#32483): a step's fields never mix a failed call with a good one.
            if verdict.gate, verdict.transferProvider != nil, let userID {
                decision.callerOwns = try await target.callerOwns()
                verdict = decision.verdict
                if verdict.readsMachine { try await decision.readGuest(exec: { (try? await api.exec(machineID, command: $0, timeoutMs: 20_000))?.stdout }, pause: CloudCredentialTransfer.guestCheckPause) } // again until a new guest binds
                // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
                if verdict.transferProvider == .claude, decision.verdict.guestTakesLogin { decision.take(await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID, otherTeams: otherTeams)) }
            }
            verdict = decision.verdict
            guard let provider = verdict.transferProvider, let userID else { return false }
            // No visible login on a start: with no cached login for this person, no terminal, no
            // `setup-token` and no modal. The chat's own "Sign in to Claude" card (acpmux
            // `agent_login`, #33744) signs the machine in with one click and the provider's approve
            // page, and only the person's click starts it (Leo, 2026-11-04: "we literally said we
            // were gonna do is such that you literally dont need to log in").
            // A Keychain that did not answer is recorded as such, never as "no cached login"; a check cancelled with its start throws.
            if provider == .claude, [.install, .confirmThenInstall, .askConsent].contains(verdict.step),
               let outcome = try await CloudCredentialTransfer.CachedLogin.startOutcome({ await CloudCredentialTransfer.cachedLogin(provider: .claude, teamID: teamID, userID: userID, otherTeams: otherTeams) }) {
                decision.outcome = outcome
                return false
            }
            // A copy nobody asked for goes only to a machine the person owns (the guest probe's "owner"), never to a team guest.
            if target.ownerOnly, verdict.guestKind != "owner" { decision.outcome = Self.notOwnerSkipped; return false }
            switch verdict.step {
            case .skip, .refuse: return false // a refusal is the start-session's error (CloudStartSession)
            case .install: break
            case .askConsent:
                guard await gate.askConsent(&decision) else { return false }
            case .confirmThenInstall:
                guard provider == .claude, await asker.ask(CloudPresenter.firstLoginAsk(machine: target.title, services: services)) == CloudPresenter.firstLoginAccept else { decision.outcome = Self.loginDeclined; return false }
                CloudHarnessLoginChoices().save(.pass, userID: userID) // Their Yes is their choice for every later machine.
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            if provider == .codex { // The Mac's broker: short-lived access, a device-code sign-in only when it holds none; it checks the account itself.
                // A machine it already serves keeps that access untouched: a failed repeat would revoke it.
                if await cloud.codexBroker.delivers(machineID: machineID, scope: .init(userID: userID, teamID: teamID)) { decision.outcome = "already delivered"; return false }
                try await cloud.codexBroker.run(machineID: machineID, scope: .init(userID: userID, teamID: teamID), confirmed: true,
                                                askLocalSignIn: { [services] in await Self.askCodexSignIn(services, mayAsk: codexPrompt, asker: asker) }) { prompt in
                    guard codexPrompt else { return false }
                    return await CloudPresenter.codexDeviceCode(prompt, asker: asker)
                }
            } else {
                let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                    allowsCreatorTeamGuest: !target.ownerOnly && verdict.guestKind == "team" && CloudCredentialTransfer.allowsCreatorTeamGuest(isDogfoodBuild: DevTools.isEnabled, defaults: .standard), otherTeams: otherTeams, openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
                try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID }, currentUserID: { cloud.auth.user?.id },
                                       confirmed: true, callerOwnsVM: target.callerOwns, stillAllowed: gate.stillAllowed)
            }
            decision.outcome = "installed"
            return true
        } catch { decision.outcome = Self.loginOutcome(error, cancelled: Task.isCancelled); return false }
    }

    /// The start record's outcome when the copy failed, before its fixed text.
    nonisolated static let loginFailed = "failed: "
    /// The warm's outcome on a machine the person does not own: no pre-copy.
    static let notOwnerSkipped = "skipped: not the owner's machine"
    /// The start record's outcome when the person said no to the copy.
    static let loginDeclined = "declined"
    /// The outcomes when this Mac held no login to give: the machine signs in with its chat's Sign in to Claude card.
    static let signInOnMachine: Set<String?> = [CloudCredentialTransfer.CachedLogin.none.startOutcome, CloudCredentialTransfer.CachedLogin.unreadable.startOutcome]
}
