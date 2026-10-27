import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDesign

/// Handles the recovery click from a failed Cloud agent turn. The tab bridge has already
/// verified the machine, session, and provider against the live tab; this layer only adds
/// the person's confirmation and calls the same scoped transfer used by new workspaces.
@MainActor
enum CloudCredentialRecovery {
    static func run(chat: String, request: AgentPaneCloudCredentialTransferRequest, services: AppServices) async -> Bool {
        guard services.cloud.isSignedIn,
              let userID = services.cloud.auth.user?.id,
              let session = services.machines.session(request.machineID),
              session.daemon.connection != nil else { return false }

        let provider = CloudCredentialTransfer.Provider(rawValue: request.provider.rawValue)!
        let providerName = provider == .claude ? "Claude" : "Codex"
        let teamName = services.cloud.auth.teamID.flatMap { id in services.cloud.auth.teams.first(where: { $0.id == id })?.displayName } ?? "Personal account"
        let body: String
        if provider == .claude {
            body = "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for (teamName)."
        } else {
            body = "cmux will start a fresh Codex device login in a visible local terminal for this VM. Codex refresh credentials are never copied between VMs; a later Codex broker can remove this per-VM login."
        }
        let spec = CmuxDialogSpec(
            title: "Set up \(providerName) on \(session.machine.title)?",
            lines: [body, "This replaces \(providerName)'s login for future launches on this VM. Existing sessions are unchanged."],
            buttons: [.cancel("Cancel"), CmuxDialogButton(id: "transfer", title: "Transfer and restart", role: .default)],
            identifier: "cmux.dialog.cloud.credentialRecovery")
        guard let window = services.windows.active?.window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard answer.button == "transfer", !answer.isDismissal else { return false }

        let transfer = CloudCredentialTransfer(
            provider: provider, machineID: request.machineID, teamID: services.cloud.auth.teamID,
            userID: userID,
            openTerminal: { [weak services] line in
                services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } ?? false
            })
        do {
            try await transfer.run(api: services.cloud.api,
                                   currentTeamID: { services.cloud.auth.teamID },
                                   currentUserID: { services.cloud.auth.user?.id },
                                   confirmed: true, refresh: true)
            return true
        } catch {
            CloudPresenter.failure(error, in: window)
            return false
        }
    }
}
