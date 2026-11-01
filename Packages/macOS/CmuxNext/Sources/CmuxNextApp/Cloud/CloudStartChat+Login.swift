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

    /// `ownerGuest`: the guest is an owner machine (`/etc/cmux/vm-kind`). `creatorTeamGuest`: this
    /// build lets a team guest whose creator is the caller receive it (DEV and dogfood, the same gate
    /// as `enabled`; every member's terminal there runs as the same Unix user, so production keeps
    /// requiring an owner guest, cmux#29774). Without it a team guest is skipped before any confirm,
    /// since the transfer's preflight would only refuse it.
    nonisolated static func loginStep(enabled: Bool, provider: CloudCredentialTransfer.Provider?, signedInUser: Bool,
                                      callerOwns: Bool, ownerGuest: Bool, creatorTeamGuest: Bool = false, machineHasLogin: Bool,
                                      cachedLogin: Bool) -> LoginStep {
        // Codex logins are per machine (its refresh token is VM-bound): its broker flow stays the
        // turn card's recovery until it gets the same treatment.
        guard enabled, provider == .claude, signedInUser, callerOwns, ownerGuest || creatorTeamGuest, !machineHasLogin else { return .skip }
        return cachedLogin ? .install : .confirmThenInstall
    }

    /// The guest's own kind, as the transfer's preflight reads it. Exits 0 on an owner machine.
    static let ownerGuestProbe = #"[ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = owner ]"#
    /// A team guest (a team account's machine, its creator's included). Exits 0 on one.
    static let teamGuestProbe = #"[ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = team ]"#

    /// The probe for a login already on the machine: the image's own detection, with its config
    /// sourced as the launcher does. Exits 0 when Claude has its own sign-in there.
    static let machineLoginProbe = ". /etc/cmux/agent-config.sh >/dev/null 2>&1; . /etc/cmux/agent-auth.sh && cmux_agent_has_own_login claude"

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
            var ownerGuest = false, creatorTeamGuest = false, hasLogin = false, cached = false
            if owns { ownerGuest = (try? await api.exec(machineID, command: Self.ownerGuestProbe, timeoutMs: 20_000).exitCode) == 0 }
            // This build passes logins (the gate above), so the creator's team machine takes one too.
            if owns, !ownerGuest { creatorTeamGuest = (try? await api.exec(machineID, command: Self.teamGuestProbe, timeoutMs: 20_000).exitCode) == 0 }
            if ownerGuest || creatorTeamGuest {
                hasLogin = (try? await api.exec(machineID, command: Self.machineLoginProbe, timeoutMs: 20_000).exitCode) == 0
                if !hasLogin { cached = await CloudCredentialTransfer.hasCachedLogin(provider: provider, teamID: teamID, userID: userID) }
            }
            switch Self.loginStep(enabled: enabled, provider: provider, signedInUser: true, callerOwns: owns,
                                  ownerGuest: ownerGuest, creatorTeamGuest: creatorTeamGuest, machineHasLogin: hasLogin, cachedLogin: cached) {
            case .skip: return false
            case .install: break
            case .confirmThenInstall:
                guard await CloudPresenter.confirmFirstLogin(provider: provider, machine: machine.machine.title, services: services) else { return false }
            }
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return false }
            let transfer = CloudCredentialTransfer(provider: provider, machineID: machineID, teamID: teamID, userID: userID,
                allowsCreatorTeamGuest: creatorTeamGuest, openTerminal: { [weak services] line in await services?.openLocalProviderLogin(line) ?? false })
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
