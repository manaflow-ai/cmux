import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// New agent chats in a workspace of another machine (an SSH machine or an owner Cloud VM,
/// cx-k21v / cx-cmok): the tab records that machine's store as its host
/// (`registry:<registry id>`), and the chat starts in that machine's own acpmux through its
/// session daemon (`agent-session-start`, policy `ask`). It never starts on this Mac: a daemon
/// without the verb, or one that refuses, leaves the tab with the reason.
extension AgentTabStore {
    /// `registry:<id>` of `daemon`'s store, the host of a new chat in one of its panes; nil for this
    /// Mac's daemon (its chats record `install:<id>`) or while the remote store has no id yet.
    static func registryHost(of daemon: DaemonService) -> String? {
        guard !daemon.isLocal, let id = daemon.store.registryID ?? daemon.identity?.sessionID, !id.isEmpty else { return nil }
        return AgentTabRemoteStart.registryPrefix + id.lowercased()
    }

    /// Starts the chat of tab `key` on its machine (`agent-session-start` on that machine's daemon)
    /// once, and answers its surface in that store and the new session. A tab the store is still
    /// creating starts once the store answered (the provisional surface names no daemon tab).
    func startRemoteChat(_ key: String, machine: String, endpoint: @escaping AgentSessionAttachClient.EndpointProvider) async throws
        -> AgentTabRemoteStart.Started {
        if let pending = remoteCreations[key] ?? remoteCreations[resolve(key)] { _ = try await pending.value() }
        let key = resolve(key)
        if let running = remoteStarts[key] { return try await running.value }
        guard let (record, store) = lookup(key), let tab = store.tab(id: key), !ProvisionalTab.isProvisional(key) else {
            throw AgentRemoteStartRefusal(code: "agent_session.unknown_tab", machine: machine)
        }
        if let session = sessions[key] ?? record.session { return .init(surface: tab.surface.rawValue, session: session) }
        let seed = await remoteSeeds[key]?.peek()
        guard let cwd = seed?.cwd ?? remoteFolder?(key) else { throw AgentRemoteStartRefusal.folderNeeded(machine: machine) }
        let surface = tab.surface.rawValue
        let harness = seed?.harness
        // task-owner: one start per tab; stored in remoteStarts so a reconnecting page waits for it
        let task = Task<AgentTabRemoteStart.Started, any Error> {
            let client = AgentSessionAttachClient(surface: surface, requestTimeout: AgentTabRemoteStart.timeout, endpoint: endpoint)
            let result: Result<String, any Error>
            do { result = .success(try await client.start(cwd: cwd, harness: harness)) } catch { result = .failure(error) }
            await client.close()
            switch result {
            case .success(let session): return .init(surface: surface, session: session)
            case .failure(let error as AgentSessionAttachError):
                throw AgentRemoteStartRefusal(code: error.code, machine: machine, folder: cwd, detail: error.message)
            case .failure(let error): throw error
            }
        }
        remoteStarts[key] = task
        defer { remoteStarts[key] = nil }
        let started = try await task.value
        // The daemon bound the session on its tab (it is the record's writer); this is the view mirror.
        sessions[resolve(key)] = started.session
        return started
    }
}

/// The start of a new chat on another machine, as the remote pane host calls it.
nonisolated enum AgentTabRemoteStart {
    static let registryPrefix = MachineRegistry.registryHostPrefix
    /// acpmux has 60 s to create the session on its machine (spec), plus the carrier.
    static let timeout: Duration = .seconds(75)

    struct Started: Sendable, Equatable {
        let surface: UInt64
        let session: String
    }
}

/// Why a chat could not start on another machine, in the user's language. ONE table maps every
/// typed refusal of `agent-session-start` (cmux-tui/spec/commands.md) and the app's own checks.
nonisolated struct AgentRemoteStartRefusal: LocalizedError, Equatable {
    let code: String
    let machine: String
    var folder: String?
    var detail: String?

    /// No folder to start in (no seed folder, no folder in the workspace).
    static let folderNeededCode = "app.folder_needed"
    /// The tab's host names another machine than the store that lists it (MachineRegistry).
    static let hostMismatchCode = "app.host_mismatch"

    static func folderNeeded(machine: String) -> Self { Self(code: folderNeededCode, machine: machine) }
    static func startUnsupported(machine: String) -> Self { Self(code: AgentSessionAttachClient.startUnsupported, machine: machine) }

    var errorDescription: String? {
        switch code {
        case "agent_session.untrusted_folder":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.untrustedFolder",
                                  "%1$@ is not a trusted folder on %2$@. Trust it on that machine, then start the chat again.",
                                  folder ?? "~", machine)
        case "agent_session.not_asking":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.harnessRefused",
                                  "This agent cannot ask before it acts on %@, so it cannot run there from this Mac. Pick another agent.", machine)
        case "agent_session.team_vm_blocked":
            RefusalStrings.text("handlers.refusal.agentRemoteStart.teamVM",
                                "Agent chats cannot be started from this Mac on a team VM yet.")
        case "agent_session.host_unverified":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.hostUnverified",
                                  "%@ could not confirm what kind of Cloud machine it is, so no agent chat starts there.", machine)
        case AgentSessionAttachClient.startUnsupported, "agent_session.unsupported":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateRemote",
                                  "The cmux-tui on %@ cannot start agent chats yet. Update cmux-tui on that machine.", machine)
        case "agent_session.acpmux_unavailable":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.agentServiceDown",
                                  "The agent service on %@ did not start.", machine)
        case "agent_session.timeout":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.timeout",
                                  "%@ did not start the agent in time. Try again.", machine)
        case Self.folderNeededCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.folderNeeded",
                                  "Open a terminal in a folder on %@ first; the chat starts there.", machine)
        case Self.hostMismatchCode:
            RefusalStrings.text("handlers.refusal.agentRemoteStart.hostMismatch",
                                "This chat belongs to another machine, so it does not run here.")
        default:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.refused",
                                  "%1$@ refused to start the agent chat (%2$@).", machine, code)
        }
    }
}

/// The pane host of an agent tab that cannot show its chat: its handshake says why (no chat on
/// this Mac in its place).
nonisolated struct AgentTabRefusedHost: AgentPaneHostProviding {
    let refusal: AgentRemoteStartRefusal

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw refusal }
}
