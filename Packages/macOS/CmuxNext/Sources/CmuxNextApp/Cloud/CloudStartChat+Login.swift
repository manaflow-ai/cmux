import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// A `cloud.startChat` chat's harness login, before its first prompt (Leo, 2026-10-31: "A TOKEN GETS
/// PASSED"). On a machine the signed-in person owns (the attach answer's `vmKind == "owner"`, which a
/// team machine's creator gets too, #28788), Claude gets the person's own `claude setup-token`
/// login through ``CloudCredentialTransfer``: silently when cmux already holds that login for this
/// account, else after one confirm that runs `setup-token` once in a visible local terminal. Every
/// later machine of the account then gets it with no prompt.
///
/// DEV and dogfood only (``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:defaults:)``;
/// Leo: "IN THE ACTUAL PRODUCTION APP IT MAY BE AGAINST TOS"). The relay alternative, which keeps
/// the token on the Mac, is scoped in cmux#29766.
///
/// The decision's rules are Rust's (``CloudHarnessLoginDecision``, cmux-cloud-start-core); this
/// extension reads the machine and the account and acts on it.
///
/// Never blocks the chat: a machine that is not the person's, a cancelled confirm or a failed install
/// opens the chat anyway, and its turn card still offers recovery (#26148).
extension CloudStartChat {
    /// This process's answer to ``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:defaults:)``.
    nonisolated static var passesHarnessLoginHere: Bool {
        CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: DevTools.isEnabled, defaults: .standard)
    }

    /// Gives the start's machine the person's Claude login when this build passes it. Returns
    /// whether a login was installed; never throws. `cmux cloud start-session` passes it the same way.
    func passHarnessLogin(harness: String?, machine: CloudMachineSession) async -> Bool {
        let cloud = services.cloud, userID = cloud.auth.user?.id
        let teamID = cloud.auth.teamID, machineID = machine.machineID
        let api = cloud.machineAPI.pinningTeam(teamID)
        var decision = CloudHarnessLoginDecision(dogfood: DevTools.isEnabled, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: userID != nil)
        // Never silent (CloudHarnessLoginDecision): the reason goes to the log and the machine's `cloud.machines` row.
        defer {
            machine.harnessLogin = decision
            cloud.logger.info("cloud start chat: harness login \(decision.summary, privacy: .public)")
        }
        do {
            var verdict = decision.verdict // One FFI answer per step (cmux#32483): a step's fields never mix a failed call with a good one.
            if verdict.gate, verdict.transferProvider == .claude, let userID {
                decision.callerOwns = try await cloud.callerOwnsVM(machineID)
                verdict = decision.verdict
                if verdict.readsMachine { decision.guestStdout = (try? await api.exec(machineID, command: verdict.guestKindProbe, timeoutMs: 20_000))?.stdout }
                // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
                if decision.verdict.guestTakesLogin { decision.take(await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID)) }
            }
            verdict = decision.verdict
            guard let provider = verdict.transferProvider, let userID else { return false }
            switch verdict.step {
            case .skip: return false
            case .install: break
            case .confirmThenInstall:
                guard await CloudPresenter.confirmFirstLogin(provider: provider, machine: machine.machine.title, services: services) else {
                    decision.outcome = "declined"
                    return false
                }
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                allowsCreatorTeamGuest: verdict.guestKind == "team", openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
            try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID }, currentUserID: { cloud.auth.user?.id },
                                   confirmed: true, callerOwnsVM: { try await cloud.callerOwnsVM(machineID) })
            decision.outcome = "installed"
            return true
        } catch {
            // The message is the transfer's fixed text, never provider output.
            decision.outcome = "failed: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error)))
            return false
        }
    }
}
