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

    /// What the start does about the login: nothing, install with no prompt, or ask once first.
    enum LoginStep: Equatable { case skip, install, confirmThenInstall }

    /// `ownerGuest`: the guest is an owner machine (`/etc/cmux/vm-kind`). A team guest, a creator's
    /// included, is skipped before any confirm: every member's terminal there runs as the same Unix
    /// user, so the transfer's preflight refuses it (``CloudCredentialInstaller``), and asking first
    /// would only end in that refusal. Team machines are cmux#29774.
    nonisolated static func loginStep(enabled: Bool, provider: CloudCredentialTransfer.Provider?, signedInUser: Bool,
                                      callerOwns: Bool, ownerGuest: Bool, machineHasLogin: Bool, cachedLogin: Bool) -> LoginStep {
        // Codex logins are per machine (its refresh token is VM-bound): its broker flow stays the
        // turn card's recovery until it gets the same treatment.
        guard enabled, provider == .claude, signedInUser, callerOwns, ownerGuest, !machineHasLogin else { return .skip }
        return cachedLogin ? .install : .confirmThenInstall
    }

    /// The guest's own kind, as the transfer's preflight reads it. Exits 0 on an owner machine.
    static let ownerGuestProbe = #"[ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = owner ]"#

    /// Gives the start's machine the person's Claude login when this build passes it. Returns
    /// whether a login was installed; never throws.
    func passHarnessLogin(_ start: AgentPaneCloudStart, machine: CloudMachineSession) async -> Bool {
        let cloud = services.cloud
        let enabled = Self.passesHarnessLoginHere
        guard enabled, let provider = Self.loginProvider(harness: start.harness), provider == .claude,
              let userID = cloud.auth.user?.id else { return false }
        let teamID = cloud.auth.teamID, machineID = machine.machineID
        let api = cloud.machineAPI.pinningTeam(teamID)
        do {
            let owns = try await cloud.callerOwnsVM(machineID)
            var ownerGuest = false, hasLogin = false, cached = false
            if owns { ownerGuest = (try? await api.exec(machineID, command: Self.ownerGuestProbe, timeoutMs: 20_000).exitCode) == 0 }
            // A login the provider rejects (a reused machine's expired token) is replaced like a missing one.
            if ownerGuest {
                let read = await CloudMachineLogin.read(on: api, machineID: machineID, teamID: teamID, userID: userID)
                (hasLogin, cached) = (!read.login.needsLogin, read.cached)
            }
            switch Self.loginStep(enabled: enabled, provider: provider, signedInUser: true, callerOwns: owns,
                                  ownerGuest: ownerGuest, machineHasLogin: hasLogin, cachedLogin: cached) {
            case .skip: return false
            case .install: break
            case .confirmThenInstall:
                guard await CloudPresenter.confirmFirstLogin(provider: provider, machine: machine.machine.title, services: services) else { return false }
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
            try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID }, currentUserID: { cloud.auth.user?.id },
                                   confirmed: true, callerOwnsVM: { try await cloud.callerOwnsVM(machineID) })
            return true
        } catch {
            // The message is the transfer's fixed text, never provider output.
            cloud.logger.error("cloud start chat: passing the harness login failed: \((error as? LocalizedError)?.errorDescription ?? "error", privacy: .public)")
            return false
        }
    }
}
