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
        // Non-Cloud hosts retain the folder picker fallback. A Cloud host owns
        // the no-folder choice in Rust and receives no cwd so it can create a
        // fresh `~/chats/<chat-id>` folder on the machine.
        var fallback = absolute(chosen) ?? absolute(seed?.cwd) ?? remoteFolder?(key)
        var supportsNoCwd = false
        if fallback == nil {
            let lister = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
            if ownerLink != nil { supportsNoCwd = (try? await lister.supportsNoCwd()) == true }
            if !supportsNoCwd { fallback = try? await lister.folders().work }
            await lister.close()
        }
        if fallback == nil && !supportsNoCwd {
            throw AgentRemoteStartRefusal.folderNeeded(machine: machine)
        }
        let client = AgentSessionAttachClient(surface: surface, requestTimeout: AgentTabRemoteStart.timeout, reconnect: reconnect, endpoint: endpoint)
        let result: Result<String, any Error>
        let home = fallback.map { existingView(key)?.model.transport.remoteHomeChosen.contains($0) == true } ?? false // the person's Use Home Folder (cx-1bhjj)
        let harness = chosenHarness ?? seed?.harness
        // A default model pick is omitted by the page. After a harness switch it must remain
        // that harness's default, rather than restoring the previous harness's seeded model.
        let model = chosenModel ?? (harness == seed?.harness ? seed?.model : nil)
        do { result = .success(try await client.start(cwd: fallback, harness: harness, homeConfirmed: home, personKey: personKey, ownerLink: ownerLink, model: model)) } catch { result = .failure(error) }
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
            throw AgentRemoteStartRefusal(code: code, machine: machine, folder: fallback, detail: error.message,
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

extension AgentRemoteStartRefusal { static let folderNeededCode = "app.folder_needed" } // folderNeeded(machine:)'s code (defaults guard key)
