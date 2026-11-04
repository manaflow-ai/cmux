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
    /// Gives the start's machine the person's Claude or Codex login when this build passes it. Returns
    /// whether a login was installed; never throws. `cmux cloud start-session` passes it the same way, with no Codex prompt.
    func passHarnessLogin(harness: String?, machine: CloudMachineSession, codexPrompt: Bool = true, ask: CloudHarnessLoginAsk = .init()) async -> Bool {
        let cloud = services.cloud, userID = cloud.auth.user?.id
        let teamID = cloud.auth.teamID, machineID = machine.machineID, api = cloud.machineAPI.pinningTeam(teamID)
        var decision = CloudHarnessLoginDecision(dogfood: DevTools.isEnabled, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: userID != nil)
        let gate = Self.loginCopyGate(services)
        await gate.read(into: &decision)
        ask.apply(to: &decision, userID: userID) // `--login`, the kept choice, and whether a prompt may show
        // Never silent (CloudHarnessLoginDecision): the reason goes to the log and the machine's `cloud.machines` row.
        defer { machine.harnessLogin = decision; cloud.logger.info("cloud start chat: harness login \(decision.summary, privacy: .public)") }
        do {
            var verdict = decision.verdict // One FFI answer per step (cmux#32483): a step's fields never mix a failed call with a good one.
            if verdict.gate, verdict.transferProvider != nil, let userID {
                decision.callerOwns = try await cloud.callerOwnsVM(machineID)
                verdict = decision.verdict
                if verdict.readsMachine { try await decision.readGuest(exec: { (try? await api.exec(machineID, command: $0, timeoutMs: 20_000))?.stdout }, pause: CloudCredentialTransfer.guestCheckPause) } // again until a new guest binds
                // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
                if verdict.transferProvider == .claude, decision.verdict.guestTakesLogin { decision.take(await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID)) }
            }
            verdict = decision.verdict
            guard let provider = verdict.transferProvider, let userID else { return false }
            switch verdict.step {
            case .skip, .refuse: return false // a refusal is the start-session's error (CloudStartSession)
            case .install: break
            case .askConsent:
                guard await gate.askConsent(&decision) else { return false }
            case .confirmThenInstall:
                guard await CloudPresenter.confirmFirstLogin(provider: provider, machine: machine.machine.title, services: services) else { decision.outcome = "declined"; return false }
                CloudHarnessLoginChoices().save(.pass, userID: userID) // Their Yes is their choice for every later machine.
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            if provider == .codex { // The Mac's broker: short-lived access, a device-code sign-in only when it holds none; it checks the account itself.
                // A machine it already serves keeps that access untouched: a failed repeat would revoke it.
                if await cloud.codexBroker.delivers(machineID: machineID, scope: .init(userID: userID, teamID: teamID)) { decision.outcome = "already delivered"; return false }
                try await cloud.codexBroker.run(machineID: machineID, scope: .init(userID: userID, teamID: teamID), confirmed: true) { [weak services] prompt in
                    guard codexPrompt, let window = services?.windows.active?.window else { return false }
                    return await CloudPresenter.presentCodexDeviceCode(prompt, in: .window(window))
                }
            } else {
                let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                    allowsCreatorTeamGuest: verdict.guestKind == "team" && CloudCredentialTransfer.allowsCreatorTeamGuest(isDogfoodBuild: DevTools.isEnabled, defaults: .standard), openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
                try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID }, currentUserID: { cloud.auth.user?.id },
                                       confirmed: true, callerOwnsVM: { try await cloud.callerOwnsVM(machineID) }, stillAllowed: gate.stillAllowed)
            }
            decision.outcome = "installed"
            return true
        } catch {
            // The message is the transfer's fixed text, never provider output.
            decision.outcome = "failed: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
            return false
        }
    }
}
