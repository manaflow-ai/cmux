import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Transfer to This Mac (Cloud multiplayer, plan step 9): the one action behind the Cloud chat
/// tab's and chat page's "Transfer to This Mac" and `cmux cloud transfer-local`, for a chat on a
/// Cloud machine that no move from this Mac put there (a chat started on the machine, or someone
/// else's on a team machine). Bring Back Local (``CloudBringBack``) stays the path for a chat a
/// move took from this Mac.
///
/// The machine's folder comes into a new folder here first (`cmux link seed fetch`: a seeded git
/// project cloned from its remote with the machine's commits, staged and working changes on top;
/// a whole repository or plain files copied; secrets and ignored files stay there). Then:
///
/// - The person's own machine (``isOwner(_:user:)``): the fetch keeps the sync records
///   (`--adopt`), the chat is recorded as one a move put there (``CloudMovedChats``), and Bring
///   Back Local's own run moves it (`cmux link agent move` with the frozen pull of the turn's last
///   changes) and opens it here. A stop after the fetch leaves the chat on the machine with Bring
///   Back Local as its Retry, which builds on the fetched folder.
/// - Anyone else's chat (a team member's on a team machine): the person gets their own copy of the
///   folder, opened in a new workspace here; the chat itself stays where it runs, with its owner.
///
/// The folder is `--path` (absolute, new or empty), else a new folder named after the chat's
/// folder under `~/Cloud Transfers`. Progress and failures are toasts.
@MainActor
struct CloudTransferLocal {
    static let action: ActionID = "cloudTransferLocal"
    typealias Failure = CloudMove.Failure
    let services: AppServices

    /// The tab and chat menus' row to hide: Transfer to This Mac unless the chat runs on a machine
    /// and no move from this Mac put it there (that one has Bring Back Local).
    static func hiddenMenuItems(_ record: AgentSessionRef?, movedChats: CloudMovedChats?) -> Set<ActionID> {
        guard let record, record.host.hasPrefix(MachineRegistry.registryHostPrefix), let session = record.session,
              movedChats?.entry(host: record.host, session: session) == nil else { return [action] }
        return []
    }

    /// Starts the transfer of the invocation's machine chat tab. Throws, before anything is copied,
    /// when the tab is not a machine chat or Bring Back Local owns it.
    func start(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (tab, _) = context.daemonTab(invocation) else { return }
        guard let record = tab.agentSession, record.host.hasPrefix(MachineRegistry.registryHostPrefix),
              let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)] else {
            throw ActionFailure(message: CloudTransferLocalStrings.notAMachineChat)
        }
        if services.cloud.movedChats.entry(host: record.host, session: session) != nil {
            // Already a moved chat here (this Mac moved it, or a transfer fetched its folder): Bring Back Local finishes it.
            return try CloudBringBack(services: services).start(invocation, context: context)
        }
        let daemon = services.machines.daemon(forTab: tab)
        guard !daemon.isLocal, let machine = services.machines.session(daemon.machineID) else {
            throw ActionFailure(message: CloudTransferLocalStrings.notAMachineChat)
        }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        var folder: String?
        if let path = invocation["path"]?.stringValue, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ActionFailure(message: CloudMoveStrings.relativePath(path)) }
            folder = expanded
        }
        let copyOnly = !CloudTransferRules.isOwner(machine.machine, user: services.cloud.auth.user?.id)
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        // Bring Back Local's own toast id: its progress and stops take this toast's place.
        let toastID = "cloud-bring-back-" + tab.id
        CloudMove.toast(services, toastID, CloudTransferLocalStrings.copying, duration: CloudMove.working)
        // main-hop-allow: the same tracked action work as Bring Back Local's (``CloudBringBack``): it awaits the CLI process
        // and the daemon off the main thread and only updates toasts and the moved-chats ledger between those awaits.
        let work: ActionWork = Task { @MainActor in
            do {
                let fetched = try await fetch(tab: tab, record: record, session: session, machine: machine, folder: folder, copyOnly: copyOnly,
                                              cli: cli, invocation: invocation)
                if copyOnly {
                    try await openCopy(fetched.localChat, name: tab.titleText)
                    CloudMove.toast(services, toastID, CloudTransferLocalStrings.copied(machine.machine.title), duration: .seconds(8))
                    return nil
                }
                services.cloud.movedChats.record(fetched)
                // The chat moves as a move from this Mac would come back (its toasts, Retry and recovery).
                try CloudBringBack(services: services).start(invocation, context: context)
                return nil
            } catch {
                let message = (error as? Failure)?.message ?? (error as? ActionFailure)?.message
                    ?? CloudTransferLocalStrings.failed(CloudStrings.errorText(error))
                services.cloud.logger.error("cloud transfer to this Mac failed: \(message, privacy: .public)")
                CloudMove.toast(services, toastID, message, duration: .seconds(12))
                return ActionWorkFailure(message)
            }
        }
        services.registry.track(work)
    }

    /// Copies the machine's folder of the chat into `folder` (else a new one) and answers the
    /// ledger entry the chat would have had, had a move from this Mac put it there.
    private func fetch(tab: TabModel, record: AgentSessionRef, session: String, machine: CloudMachineSession, folder: String?,
                       copyOnly: Bool, cli: CloudMoveCLI, invocation: ActionInvocation) async throws -> CloudMovedChats.Entry {
        let name = machine.machine.title
        guard let remoteChat = remoteFolder(of: tab, on: machine) else { throw Failure(message: CloudTransferLocalStrings.noFolder) }
        _ = try await CloudMove.connected(machine, invocation)
        guard let socket = await machine.daemon.connection?.endpoint?.socketPath else {
            throw Failure(message: CloudMoveStrings.notConnected(name))
        }
        let local: String
        if let folder { local = folder } else { local = await Self.newFolder(named: (remoteChat as NSString).lastPathComponent) }
        let answer: CloudMoveCLI.Answer
        do {
            answer = try await cli.transferFetch(socket: socket, local: local, remote: remoteChat, adopt: !copyOnly)
        } catch {
            throw Failure(message: CloudTransferLocalStrings.copyFailed(name, CloudStrings.errorText(error)))
        }
        guard answer.ok else {
            if answer.errorCode == CloudMoveStrings.outdatedCode { throw Failure(message: CloudBringBackStrings.outdatedMachine(name)) }
            throw Failure(message: CloudTransferLocalStrings.refusal(answer, machine: name, folder: local) ?? CloudBringBackStrings.conflict(answer.conflicts))
        }
        let (root, localChat) = CloudTransferRules.localChat(local: local, remoteChat: remoteChat, remoteRoot: answer.remoteRoot)
        return CloudMovedChats.Entry(machineID: machine.machineID, host: record.host, session: session, harness: record.harness,
                                     localRoot: local, localChat: localChat, remoteFolder: root, remoteChat: remoteChat, name: tab.titleText)
    }

    /// The chat's folder on the machine: its tab's, else a terminal's in its workspace there.
    private func remoteFolder(of tab: TabModel, on machine: CloudMachineSession) -> String? {
        if let cwd = tab.cwd, cwd.hasPrefix("/") { return cwd }
        let workspace = machine.daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0.tabs.contains { $0 === tab } } } }
        let tabs = workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
        return tabs.lazy.compactMap(\.cwd).first { $0.hasPrefix("/") }
    }

    /// A new folder under `~/Cloud Transfers` (``CloudTransferRules/newFolder(named:base:home:exists:)``), its
    /// names checked off the main thread.
    private static func newFolder(named name: String) async -> String {
        let base = CloudTransferLocalStrings.folderName, home = NSHomeDirectory()
        return await Task.detached(priority: .userInitiated) {
            CloudTransferRules.newFolder(named: name, base: base, home: home) { FileManager.checked.fileExists(atPath: $0) }
        }.value
    }

    /// The person's copy: a new workspace here with a terminal in the copied folder.
    private func openCopy(_ folder: String, name: String) async throws {
        guard let connection = services.daemon.connection else { throw DaemonError.notConnected }
        let workspace = NewWorkspacePlacements.placedKey(in: services.windows)
        _ = try await WorkspaceCreation.createWithFirstTab(workspace, name: name.isEmpty ? nil : name, on: connection,
                                                           repair: services.emptyWorkspaces) { result in
            try await connection.createTerminal(in: result.key, cwd: folder)
        }
        services.windows.reveal(workspaceID: workspace.rawValue)
    }
}
