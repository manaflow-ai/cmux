import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// New agent chats in a workspace of another machine (SSH, owner Cloud VM; cx-k21v): the tab's
/// host is that store (`registry:<id>`); the chat starts in that machine's acpmux
/// (`agent-session-start`, policy `ask`) at the first send, never on this Mac.
extension AgentTabStore {
    /// `registry:<id>` of `daemon`'s store (a new chat's host there); nil for this Mac or no id yet.
    static func registryHost(of daemon: DaemonService) -> String? {
        guard !daemon.isLocal, let id = daemon.store.registryID ?? daemon.identity?.sessionID, !id.isEmpty else { return nil }
        return AgentTabRemoteStart.registryPrefix + id.lowercased()
    }

    /// Tab `key` as its machine's store lists it (surface, session once started); waits for a tab
    /// being created, starts nothing; nil until the tree lists it (the start reads it again).
    func existingRemoteChat(_ key: String) async throws -> (surface: UInt64, session: String?)? {
        if let pending = remoteCreations[key] ?? remoteCreations[resolveRemote(key)] { _ = try await pending.value() }
        let key = resolveRemote(key)
        guard let (record, store) = lookup(key), let tab = store.tab(id: key), !ProvisionalTab.isProvisional(key) else {
            return nil
        }
        return (tab.surface.rawValue, sessions[key] ?? record.session)
    }

    /// Starts tab `key`'s chat on its machine (`agent-session-start`) once, from the page's first
    /// send, in the page's folder and agent (nil: the seed's, then a workspace folder there).
    func startRemoteChat(_ key: String, machine: String, cwd: String? = nil, harness: String? = nil, model: String? = nil,
                         personKey: AgentSessionAttachClient.PersonKey? = nil, ownerLink: AgentSessionAttachClient.OwnerLink? = nil,
                         teammate: AgentSessionAttachClient.Teammate? = nil, reconnect: AgentSessionAttachClient.Reconnect? = nil,
                         endpoint: @escaping AgentSessionAttachClient.EndpointProvider) async throws
        -> AgentTabRemoteStart.Started {
        if let running = remoteStarts[resolveRemote(key)] { return try await running.value }
        // task-owner: one start per tab, stored before its first wait, so a ready and a reconnect
        // handshake that overlap share it (the daemon refuses a second start with `limit`)
        let task = Task<AgentTabRemoteStart.Started, any Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await runRemoteStart(key, machine: machine, cwd: cwd, harness: harness, model: model, personKey: personKey,
                                            ownerLink: ownerLink, teammate: teammate, reconnect: reconnect, endpoint: endpoint)
        }
        remoteStarts[resolveRemote(key)] = task
        defer { if remoteStarts[resolveRemote(key)] == task { remoteStarts[resolveRemote(key)] = nil } }
        return try await task.value
    }

    private func runRemoteStart(_ key: String, machine: String, cwd chosen: String?, harness chosenHarness: String?, model chosenModel: String?,
                                personKey: AgentSessionAttachClient.PersonKey?, ownerLink: AgentSessionAttachClient.OwnerLink?,
                                teammate: AgentSessionAttachClient.Teammate?, reconnect: AgentSessionAttachClient.Reconnect?,
                                endpoint: @escaping AgentSessionAttachClient.EndpointProvider) async throws
        -> AgentTabRemoteStart.Started {
        if let pending = remoteCreations[key] ?? remoteCreations[resolveRemote(key)] { _ = try await pending.value() }
        let key = resolveRemote(key)
        guard let (record, store) = lookup(key), let tab = store.tab(id: key), !ProvisionalTab.isProvisional(key) else {
            throw AgentRemoteStartRefusal(code: "agent_session.unknown_tab", machine: machine)
        }
        let surface = tab.surface.rawValue
        if let session = sessions[key] ?? record.session { return .init(surface: surface, session: session) }
        // A teammate's Cloud machine (the Cloud API's answer on its link): its owner starts chats
        // there, so none is sent, and the card offers New Cloud Machine (cmux#29214). The owner
        // check below is unchanged: only an owner answer ever sends a start.
        if ownerLink != nil, let teammate, await teammate() { throw AgentRemoteStartRefusal.teamMachine(machine: machine) }
        let seed = await remoteSeeds[key]?.peek()
        // Only an absolute folder of that machine (a `~` or relative one is not its path).
        let absolute = { (path: String?) in path.flatMap { $0.hasPrefix("/") ? $0 : nil } }
        // No folder picked and none in its workspace: that machine's own work folder (`~/work`,
        // `agent-session-folders`), never a dead end (Leo, 2026-10-31). An older daemon has none.
        // Its own connection, so the start's owner-checked one is made for the start alone.
        var fallback = absolute(chosen) ?? absolute(seed?.cwd) ?? remoteFolder?(key)
        if fallback == nil {
            let lister = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
            fallback = try? await lister.folders().work
            await lister.close()
        }
        guard let cwd = fallback else {
            throw AgentRemoteStartRefusal.folderNeeded(machine: machine)
        }
        let client = AgentSessionAttachClient(surface: surface, requestTimeout: AgentTabRemoteStart.timeout, reconnect: reconnect, endpoint: endpoint)
        let result: Result<String, any Error>
        let home = existingView(key)?.model.transport.remoteHomeChosen.contains(cwd) == true // the person's Use Home Folder (cx-1bhjj)
        let harness = chosenHarness ?? seed?.harness
        // A default model pick is omitted by the page. After a harness switch it must remain
        // that harness's default, rather than restoring the previous harness's seeded model.
        let model = chosenModel ?? (harness == seed?.harness ? seed?.model : nil)
        do { result = .success(try await client.start(cwd: cwd, harness: harness, homeConfirmed: home, personKey: personKey, ownerLink: ownerLink, model: model)) } catch { result = .failure(error) }
        await client.close()
        switch result {
        case .success(let session):
            // The daemon bound the session on its tab (it is the record's writer); this is the view mirror.
            if lookup(resolveRemote(key)) != nil { sessions[resolveRemote(key)] = session }
            return .init(surface: surface, session: session)
        case .failure(let error as AgentSessionAttachError):
            // A start whose answer was lost already bound the tab: show that chat.
            if error.code == "agent_session.bound", let session = lookup(resolveRemote(key))?.record.session {
                return .init(surface: surface, session: session)
            }
            // A link that came up as a teammate's while the start connected is refused as one.
            let code = AgentSessionAttachError.classified(error.code, teammate: await teammate?() ?? false)
            throw AgentRemoteStartRefusal(code: code, machine: machine, folder: cwd, detail: error.message,
                                          keyedRestartSafe: error.keyedRestartSafe)
        case .failure(let error):
            throw error
        }
    }
}

/// The start of a new chat on another machine, as the remote pane host calls it.
nonisolated enum AgentTabRemoteStart {
    static let registryPrefix = MachineRegistry.registryHostPrefix
    /// acpmux has 60 s to create the session on its machine (spec), plus the carrier.
    static let timeout: Duration = .seconds(75)

    /// The project list of a chat on another machine: its workspaces' folders, then the folders the
    /// machine lists itself, each once, in that order.
    static func folders(listed: [String], machine: [String]) -> [String] {
        var seen = Set<String>()
        return (listed + machine).filter { seen.insert($0).inserted }
    }

    struct Started: Sendable, Equatable {
        let surface: UInt64
        let session: String
    }
}

/// Why a chat could not start on another machine, in the user's language. ONE table maps every
/// typed refusal of `agent-session-start` (cmux-tui/spec/commands.md) and the app's own checks.
nonisolated struct AgentRemoteStartRefusal: LocalizedError, AgentPaneHostRefusal, Equatable {
    let code: String
    let machine: String
    var folder: String?
    var detail: String?
    /// `agent_session.needs_keyed_start`: the machine's daemon says a keyed restart of its acpmux
    /// loses nothing (cx-0w0jj); nil for any other refusal.
    var keyedRestartSafe: Bool?

    /// No folder to start in (no seed folder, no folder in the workspace).
    static let folderNeededCode = "app.folder_needed"
    /// The tab's host names another machine than the store that lists it (MachineRegistry).
    static let hostMismatchCode = "app.host_mismatch"

    static func folderNeeded(machine: String) -> Self { Self(code: folderNeededCode, machine: machine) }
    /// The refusal of a start on a teammate's machine (the card's New Cloud Machine, startRefusal.ts).
    static func teamMachine(machine: String) -> Self { Self(code: AgentSessionAttachError.teamMachine, machine: machine) }
    /// An untrusted folder on a machine whose cmux-tui cannot take the person's Trust from here.
    var withoutTrust: Self { code == "agent_session.untrusted_folder" ? Self(code: "app.trust_update", machine: machine, folder: folder) : self }
    static func startUnsupported(machine: String) -> Self { Self(code: AgentSessionAttachClient.startUnsupported, machine: machine) }

    var userMessage: String { errorDescription ?? code }

    var machineName: String? { machine.isEmpty ? nil : machine }

    var errorDescription: String? {
        switch code {
        case "agent_session.untrusted_folder":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.untrustedFolder",
                                  "%1$@ is not a trusted folder on %2$@. Trust it on that machine, then start the chat again.",
                                  folder ?? "~", machine)
        case "agent_session.not_asking":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.harnessRefused",
                                  "This agent cannot ask before it acts on %@, so it cannot run there from this Mac. Pick another agent.", machine)
        case AgentSessionAttachError.teamMachine:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.teamVM",
                                  "%@ is a teammate's machine, so its owner starts chats there. Pick your own machine, or create one with New Cloud Machine.", machine)
        case "agent_session.host_unverified":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.hostUnverified",
                                  "%@ could not confirm what kind of Cloud machine it is, so no agent chat starts there.", machine)
        case AgentSessionAttachClient.startUnsupported, "agent_session.unsupported":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateRemote",
                                  "The cmux-tui on %@ cannot start agent chats yet. Update cmux-tui on that machine.", machine)
        case "agent_session.acpmux_unavailable":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.agentServiceDown",
                                  "The agent service on %@ did not start.", machine)
        case "agent_session.limit":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.busy",
                                  "%@ is starting other agent chats. Try again in a moment.", machine)
        case "agent_session.timeout":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.timeout",
                                  "%@ did not start the agent in time. Try again.", machine)
        case "agent_session.home_unconfirmed": RefusalStrings.format("handlers.refusal.agentRemoteStart.homeUnconfirmed", "Choose the home folder on %@ with Use Home Folder first.", machine)
        case "agent_session.above_home": RefusalStrings.format("handlers.refusal.agentRemoteStart.aboveHome", "A chat on %@ never runs in a folder above its home folder.", machine)
        case "app.trust_update":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateForTrust", "Update cmux on %@ to trust folders from here.", machine)
        case Self.folderNeededCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.folderNeeded",
                                  "%@ has no work folder to start in. Use Choose folder to pick one there.", machine)
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
