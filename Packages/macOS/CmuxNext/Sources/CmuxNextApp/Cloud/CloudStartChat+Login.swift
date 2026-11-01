import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// A `cloud.startChat` chat's harness login, before its first prompt (Leo, 2026-10-31: "A TOKEN GETS
/// PASSED"). On a machine the signed-in person owns (the attach answer's `vmKind == "owner"`) whose
/// guest is an owner machine (no teammate shares its Unix user; a team machine, its creator's
/// included, is left alone, cmux#29774), Claude gets the person's own `claude setup-token`
/// login through ``CloudCredentialTransfer``: silently when cmux already holds that login for this
/// account, else after one confirm that runs `setup-token` once in a visible local terminal. Every
/// later machine of the account then gets it with no prompt.
///
/// DEV and dogfood only (``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:setting:)``;
/// Leo: "IN THE ACTUAL PRODUCTION APP IT MAY BE AGAINST TOS"). The relay alternative, which keeps
/// the token on the Mac, is scoped in cmux#29766.
///
/// Never blocks the chat: a machine that is not the person's, a cancelled confirm or a failed install
/// opens the chat anyway, and its turn card still offers recovery (#26148).
extension CloudStartChat {
    /// This process's answer to ``CloudCredentialTransfer/passesHarnessLogin(isDogfoodBuild:setting:)``.
    nonisolated static var passesHarnessLoginHere: Bool {
        CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: DevTools.isEnabled, defaults: .standard)
    }

    /// The provider whose login a start needs; nil for a harness that has no transfer (pi, opencode).
    /// No harness named is the app's default agent, Claude.
    nonisolated static func loginProvider(harness: String?) -> CloudCredentialTransfer.Provider? {
        guard let harness, !harness.isEmpty else { return .claude }
        return AgentPaneCloudCredentialTransferRequest.Provider(harnessID: harness).flatMap { CloudCredentialTransfer.Provider(rawValue: $0.rawValue) }
    }

    /// Gives the start's machine the person's Claude login when this build passes it. Returns
    /// whether a login was installed; never throws.
    func passHarnessLogin(_ start: AgentPaneCloudStart, machine: CloudMachineSession) async -> Bool {
        let cloud = services.cloud, provider = Self.loginProvider(harness: start.harness), userID = cloud.auth.user?.id
        let teamID = cloud.auth.teamID, machineID = machine.machineID
        let api = cloud.machineAPI.pinningTeam(teamID)
        var decision = CloudHarnessLoginDecision(gate: Self.passesHarnessLoginHere, provider: provider, signedIn: userID != nil)
        // Never silent (CloudHarnessLoginDecision): the reason goes to the log and the machine's `cloud.machines` row.
        defer {
            machine.harnessLogin = decision.summary
            cloud.logger.info("cloud start chat: harness login \(decision.summary, privacy: .public)")
        }
        do {
            if decision.gate, provider == .claude, let userID {
                decision.callerOwns = try await cloud.callerOwnsVM(machineID)
                if decision.readsMachine {
                    let kind = try? await api.exec(machineID, command: CloudHarnessLoginDecision.guestKindProbe, timeoutMs: 20_000)
                    decision.guestKind = kind.flatMap { CloudHarnessLoginDecision.guestKind(stdout: $0.stdout) }
                }
                // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
                if decision.guestKind == "owner" {
                    let read = await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID)
                    (decision.machineLogin, decision.cached) = (read.login, read.cached)
                }
            }
            guard let provider, let userID else { return false }
            switch decision.step {
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
                openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
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
