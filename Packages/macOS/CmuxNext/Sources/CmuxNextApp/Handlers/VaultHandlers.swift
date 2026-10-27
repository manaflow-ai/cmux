import AppKit
import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextHistory
import Foundation

/// The session vault's actions: Open Vault as Pane, and the row actions of
/// the vault list (its context menu, `cmux action run`, MCP). A row action
/// acts on the invocation's `session` (a qualified or provider session id),
/// else on the vault's selected row.
enum VaultHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("palette.openVaultPane", run: { invocation in
            guard let pane = context.paneController(invocation) else { return }
            services.vaultPages.open(in: pane)
        })
        registry.bind("vaultFocusSession", run: { invocation in
            let session = try Self.session(invocation, services)
            guard services.vault.isLive(session), let tab = session.tab, services.revealTab(tab) else {
                throw ActionFailure(message: VaultStrings.notRunning)
            }
        })
        registry.bind("vaultOpenSession", run: { invocation in
            let session = try Self.session(invocation, services)
            HistoryRestorer(services: services).resume(session)
        })
        registry.bind("vaultResumeInNewWorkspace", run: { invocation in
            let session = try Self.session(invocation, services)
            guard let command = session.resumeCommand else { throw ActionFailure(message: HistoryAppStrings.noResume) }
            guard let daemon = services.machines.daemons.first(where: { $0.machineID == session.machine }) else {
                throw ActionFailure(message: HistoryAppStrings.machineOffline)
            }
            let spawn = WorkspaceSpawn(cwd: session.cwd, name: session.cwd.flatMap(WorkspaceSpawn.folderName), command: command)
            let windows = services.windows
            // The create is awaited off main; its failure is the run's, in one task on main.
            services.registry.trackWork(owner: "VaultHandlers.resume", on: services.mainWork) {
                _ = try await windows.createWorkspace(spawn, on: daemon)
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure(RefusalStrings.describe(error))
            }
        })
        registry.bind("vaultCopyResumeCommand", run: { invocation in
            let session = try Self.session(invocation, services)
            guard let text = VaultResumeCommand(session: session).text else { throw ActionFailure(message: HistoryAppStrings.noResume) }
            services.vault.copy(text)
        })
        registry.bind("vaultOpenPullRequest", run: { invocation in
            let session = try Self.session(invocation, services)
            let pullRequests = services.vault.pullRequests, vault = services.vault
            let provider = session.provider, sessionID = session.sessionID
            // The lookup is awaited off main; the page opens (or the run is refused) in one task on main.
            services.registry.trackWork(owner: "VaultHandlers.pullRequest", on: services.mainWork) {
                await pullRequests.url(provider: provider, sessionID: sessionID)
            } then: { result in
                guard case .success(let url?) = result else { return ActionWorkFailure(VaultStrings.noPullRequest) }
                vault.openURL(url)
                return nil
            }
        })
    }

    /// The invocation's `session`, else the vault's selection.
    private static func session(_ invocation: ActionInvocation, _ services: AppServices) throws -> AgentSession {
        let id = invocation["session"]?.stringValue
        if let session = services.vault.session(id) { return session }
        throw id == nil ? ActionFailure(message: VaultStrings.noSessionSelected) : ActionFailure.notFound(HistoryAppStrings.noSession)
    }
}
