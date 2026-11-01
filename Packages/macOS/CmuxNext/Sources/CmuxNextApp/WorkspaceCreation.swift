import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation
import os

/// Creates a workspace and its first terminal with two daemon requests
/// (create-workspace, then create-terminal), and never leaves a
/// half-created workspace: when a step fails (a timed-out create may still
/// commit later, cx-tzlqb; not a refused one), the key is closed. The
/// daemon's single atomic `workspace.create` cannot take a caller key, cwd,
/// env, terminal id or keep yet (plans: the workspace.create extension).
enum WorkspaceCreation {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.workspace-create")

    static func withTerminal<T>(
        _ key: WorkspaceKey,
        createWorkspace: () async throws -> Void,
        createTerminal: (WorkspaceKey) async throws -> T,
        closeWorkspace: (WorkspaceKey) async throws -> Void
    ) async throws -> T {
        var refused = false // a refused create made nothing (the key may name a live workspace)
        do {
            do { try await createWorkspace() } catch { refused = (error as? DaemonError).map { if case .command = $0 { true } else { false } } ?? false; throw error }
            return try await createTerminal(key)
        } catch {
            if !refused { do {
                try await closeWorkspace(key)
            } catch let closeError {
                // The create failure stays the one error the user sees.
                logger.error("closing a half-created workspace failed: \(String(describing: closeError), privacy: .public)")
            } }
            throw error
        }
    }

    /// Closes a workspace whose first terminal failed; when the close fails
    /// too, `repair` releases it (it stays, empty, with the terminal error).
    /// Only while it is empty: a first tab the daemon made after its reply's
    /// deadline is the person's workspace, never closed with it.
    @MainActor
    private static func closeHalfCreated(_ key: WorkspaceKey, on connection: DaemonConnection, repair: EmptyWorkspaceRepair) async throws {
        do {
            try await WorkspaceClose.close(key, terminals: [], on: connection, reason: .sessionEnd, ifEmpty: true)
        } catch {
            repair.closeFailed(key)
            throw error
        }
    }

    /// Creates workspace `key` (named `name`) with its first terminal
    /// (`terminal`) on `connection`, owned by `repair` while it runs: a
    /// failure closes the workspace (its terminals with it) and the repair
    /// never fills it.
    @MainActor
    static func create<T>(
        _ key: WorkspaceKey,
        name: String?,
        on connection: DaemonConnection,
        repair: EmptyWorkspaceRepair,
        terminal: (WorkspaceKey) async throws -> T
    ) async throws -> T {
        // A workspace with a terminal is a new terminal (Cmd-N, R3): its create waits through late replies under its
        // mutation id, so only the daemon's answer or the connection's end can take it back, never a clock. The first
        // terminal is the caller's (`createTerminalWaitingForStart`); a later step of `terminal` is the caller's own work.
        try await repair.populating(key) {
            try await withTerminal(
                key, createWorkspace: { _ = try await connection.createWorkspaceWaitingForReply(name: name, key: key) },
                createTerminal: terminal,
                closeWorkspace: { try await closeHalfCreated($0, on: connection, repair: repair) }
            )
        }
    }

    /// The first terminal of new workspace `key` (Cmd-N's way for every caller of ``create(_:name:on:repair:terminal:)``):
    /// keyed and waited for through a late start, so a busy daemon never makes the workspace the person sees close
    /// (P0 2026-10-30, R3).
    static func firstTerminal(in key: WorkspaceKey, cwd: String?, on connection: DaemonConnection) async throws -> CreateTerminalResult {
        try await connection.createTerminalWaitingForStart(in: key, cwd: cwd)
    }

    /// Creates workspace `key` and its first tab from `firstTab`, which gets
    /// the created workspace (its handle, for commands that take one), owned
    /// by `repair` like ``create(_:name:on:repair:terminal:)``: a failure
    /// closes the workspace. A late create reply asks again until `giveUp`
    /// (``DaemonConnection/retryingLateReplies(_:until:_:)``).
    @MainActor
    static func createWithFirstTab<T>(
        _ key: WorkspaceKey,
        name: String?,
        on connection: DaemonConnection,
        repair: EmptyWorkspaceRepair,
        giveUp: ContinuousClock.Instant? = nil,
        firstTab: (WorkspaceMutationResult) async throws -> T
    ) async throws -> T {
        try await repair.populating(key) {
            var created: WorkspaceMutationResult?
            return try await withTerminal(
                key, createWorkspace: { created = try await connection.createWorkspaceRetryingLateReplies(name: name, key: key, until: giveUp) },
                createTerminal: { _ in
                    guard let created else { throw DaemonError.notConnected }
                    return try await firstTab(created)
                },
                closeWorkspace: { try await closeHalfCreated($0, on: connection, repair: repair) }
            )
        }
    }

    /// Whether `spawn` opens on the New Tab page (or a first chat), not a terminal.
    static func opensPage(_ spawn: WorkspaceSpawn, on daemon: DaemonService, tabs: AgentTabStore) -> Bool {
        (spawn.opensNewTabPage || spawn.firstChat != nil || spawn.firstSession != nil) && spawn.command == nil
            && tabs.opensFirstPage(on: daemon, chat: spawn.firstChat != nil || spawn.firstSession != nil)
    }

    /// A person's new workspace on the New Tab page (`opensNewTabPage`),
    /// starting in `cwd`; nil when `spawn` gets a terminal instead (it runs a
    /// command, or `daemon` cannot host the page).
    @MainActor
    static func newTabPage(_ spawn: WorkspaceSpawn, _ key: WorkspaceKey, cwd: String?, on daemon: DaemonService,
                           repair: EmptyWorkspaceRepair, tabs: AgentTabStore) async throws -> String? {
        guard opensPage(spawn, on: daemon, tabs: tabs), let connection = daemon.connection else { return nil }
        return try await createWithFirstTab(key, name: spawn.name, on: connection, repair: repair) { created in
            if let session = spawn.firstSession {
                _ = try await sessionTab(session, in: created, on: daemon, tabs: tabs)
            } else {
                if let token = spawn.inputToken, spawn.firstChat == nil { tabs.firstPageTokens[created.workspace] = token }
                _ = try await tabs.openFirstPage(workspace: created.workspace, cwd: cwd, on: daemon, chat: spawn.firstChat)
            }
            return created.key.rawValue
        }
    }

    /// `session`'s chat as the first tab of `created` (the New Tab page's first chat, and
    /// `agent.openSessionWorkspace`'s only tab: no terminal beside it, Leo 2026-10-28). The record
    /// is on `host` (this Mac's acpmux, or a Chief home's `chief:<id>`); `linked` binds the tab
    /// like a `cmux://session/<id>` link (its page refuses a session the daemon does not have).
    /// Returns the tab's key.
    @MainActor
    static func sessionTab(_ session: String, in created: WorkspaceMutationResult, host: String? = nil, linked: Bool = false,
                           on daemon: DaemonService, tabs: AgentTabStore) async throws -> String {
        guard let connection = daemon.connection, let localHost = tabs.localHost else { throw DaemonError.notConnected }
        guard tabs.holdsTabs(daemon) else { throw AgentTabRefusal(message: RefusalStrings.agentTabsUnsupported) }
        // A session of this Mac never opens in a workspace of another machine (cx-k21v).
        guard daemon.isLocal else { throw AgentTabRefusal(message: RefusalStrings.agentTabMachineMismatch) }
        if let refusal = AgentTabStore.hostRefusal(host, localHost: localHost, chiefHost: tabs.chiefHost, daemonIsLocal: true) {
            throw AgentTabRefusal(message: refusal)
        }
        // A chat of that acpmux: its tab shows it as soon as the tree lists it.
        let record = AgentSessionRef(host: host ?? localHost, hostName: tabs.localHostName, session: session)
        let request = NewConversationTabRequest(agentSession: record, workspace: created.workspace,
                                                origin: AgentTabStore.createOrigin, mutationID: UUID().uuidString)
        // One mutation id for every send: a tab the daemon made after the deadline replays.
        let response = try await DaemonConnection.retryingLateReplies(NewConversationTabRequest.command) { try await connection.request(request) }
        let key = response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)"
        if linked {
            tabs.sessions[key] = session
            tabs.linkedSessions.insert(key)
            tabs.track(key, in: daemon.store)
        }
        return key
    }
}
