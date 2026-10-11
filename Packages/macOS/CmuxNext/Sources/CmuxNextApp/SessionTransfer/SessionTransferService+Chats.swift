import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Agent chats between builds (`chat` records): the chat moves from the source build's acpmux to
/// this one's with its history, queue and draft (`acpmux transfer`, cmux-tui/crates/acpmux
/// `hub/transfer_out.rs`), then opens here as a conversation tab. Builds that share one acpmux
/// (Release and NIGHTLY share `~/.acpmux`) move only the tab.
extension SessionTransferService {
    /// How long `acpmux transfer` may take; it stays under `session.transfer.pull`'s deadline so
    /// the move ends (or gives the chat back) on its own.
    static let chatMoveLimit: Duration = .seconds(240)

    /// This build's chats another build can take, by tab id: chats of this Mac's acpmux (not the
    /// Chief home's, not another machine's) that have a session.
    func localChats() -> [String: (session: String, harness: String?)] {
        guard let tabs = services?.agentTabs, let localHost = tabs.localHost else { return [:] }
        var chats: [String: (session: String, harness: String?)] = [:]
        for (key, record) in tabs.listTabs() where record.host == localHost {
            if let session = tabs.session(of: key) { chats[key] = (session, record.harness) }
        }
        return chats
    }

    /// This build's acpmux (its socket and home), nil without one.
    func acpmuxEnvironment() -> AcpmuxEnvironment? {
        services.flatMap(QuitAgents.environment)
    }

    /// Moves chat `item` into this build's acpmux and returns its session here. Its running turn
    /// stops when `interrupt`, else the move is refused. A failed move leaves it in the source.
    func moveChat(_ item: SessionTransferItem, interrupt: Bool) async throws -> String {
        guard let session = item.agentSessionID, let socket = item.acpmuxSocket else { throw Failure.missingAgentID }
        guard let services, let own = acpmuxEnvironment() else { throw Failure.unavailable }
        if socket == own.socketPath { return session }
        // `/tmp` is shared, and the source's daemon hands this one the chat's files.
        guard Self.isOwnedSocket(socket) else { throw Failure.peerRefused }
        try await (services.agentTabs.localSessionHost ?? services.agentTabs.host).prewarm()
        var environment = ProcessInfo.processInfo.environment
        environment["ACPMUX_SOCKET"] = socket
        if let home = item.acpmuxHome { environment["ACPMUX_HOME"] = home }
        let arguments = ["--json", "transfer", session, "--to", own.socketPath] + (interrupt ? ["--interrupt"] : [])
        let result = try await ProcessRunner.run(executable: own.executable, arguments: arguments, environment: environment,
                                                 timeout: Self.chatMoveLimit, clock: ContinuousClock())
        guard result.status == 0 else {
            let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.chatNotMoved(reason.isEmpty ? "acpmux exited with \(result.status)" : reason)
        }
        let moved = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        return moved?["sessionId"] as? String ?? session
    }

    /// Shows `session` of this build's acpmux in a new workspace of the active window (the tab
    /// already showing it instead, when there is one) and returns the workspace id.
    func openChat(_ session: String, title: String) async throws -> String {
        guard let services else { throw Failure.unavailable }
        let store = services.daemon.store
        if let key = services.agentTabs.tab(showing: session), let tab = store.tab(id: key),
           let pane = store.pane(containing: tab.surface), let workspace = store.workspace(containing: pane.handle)?.key {
            return workspace.rawValue
        }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        var spawn = WorkspaceSpawn(name: title.isEmpty ? nil : title)
        spawn.firstSession = session
        let id = try await services.windows.createWorkspace(spawn, into: target)
        // As for `agent` records: the source closes only for an opened conversation tab.
        guard try await hasConversationTab(id) else { throw Failure.agentNotOpened }
        return id
    }
}
