import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): one call takes a Cloud
/// machine (`--target machine:<id>`, or `--name`, created when no machine has that name), starts
/// an agent session in that machine's own acpmux, and answers `{machine_id, session_id, host}`.
///
/// The session starts the way a new chat in that machine's workspace starts at its first send: a
/// chat tab on the machine's store (`registry:<id>` host), then `agent-session-start` through the
/// machine's daemon, with this app's key when the machine takes it (``AgentTabRemoteHost/startNow``).
/// The chat's tab stays in the machine's first workspace, so the person can open it.
///
/// An agent's run (the cmux MCP server, or a shell naming its chat) never starts anything itself:
/// like an agent's Move to Cloud (``CloudMoveAsks``), it asks the person with a card in its own chat
/// (Start, Not now), and only a click on Start starts the machine and the session.
@MainActor
struct CloudStartSession {
    static let action: ActionID = "cloudStartSession"
    let services: AppServices

    /// What the run asks for, checked before anything starts.
    struct Request: Equatable {
        var machineID: String?
        /// Without a machine id: the machine with this name, created when none has it.
        var name: String?
        var agent: String
        /// A folder on the machine; nil starts in the workspace's folder there.
        var cwd: String?
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let services = context.services
        CloudHandlers.bind(action, registry, reason: reason) { invocation in
            var request = try Self.request(invocation)
            let start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
            guard CloudMoveAsks.isAgent(invocation) else {
                // A person's palette or menu run without a machine means the one they look at.
                if request.machineID == nil, request.name == nil, CloudHandlers.origin(of: invocation) == .user {
                    request.machineID = try CloudHandlers.machine(invocation, context).machineID
                }
                if request.machineID == nil, request.name == nil { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
                return CloudHandlers.result("start cloud session", context) {
                    try await runs.answer(CloudStartSessionRuns.Key(request, caller: nil), within: Self.answerWithin, pending: Self.pending(request)) {
                        try await start.run(request, invocation, context)
                    }
                }
            }
            guard request.machineID != nil || request.name != nil else { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
            guard let caller = invocation.callerAgentSession, let tab = Self.chat(caller, services: services) else {
                throw ActionFailure(message: CloudStartSessionStrings.notInChat)
            }
            let shown = request.machineID.flatMap { services.machines.session($0)?.machine.title }
            if let id = request.machineID, shown == nil { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
            let named = shown ?? request.name ?? ""
            let exists = shown != nil || services.machines.cloud.contains { $0.machine.title == named }
            let asks = services.cloud.startSessionAsks
            let text = exists ? CloudStartSessionStrings.ask(agent: request.agent, machine: named) : CloudStartSessionStrings.askNew(agent: request.agent, machine: named)
            // The person's Start is the gesture: the machine is created as theirs, at the agent's ask.
            var asPerson = ActionInvocation(target: invocation.target, arguments: invocation.arguments, origin: .user)
            asPerson.callerAgentSession = nil
            // The same ask again (the agent's run answered pending) joins the one that runs.
            let key = CloudStartSessionRuns.Key(request, caller: caller)
            CloudHandlers.result("start cloud session", context) {
                try await runs.answer(key, within: Self.answerWithin, pending: Self.pending(request)) {
                    let token = try await asks.ask(tab: tab.id, text: text, services: services)
                    asks.show(tab: tab.id, token: token, .working, CloudStartSessionStrings.starting(agent: request.agent, machine: named), services: services)
                    do {
                        let fields = try await start.run(request, asPerson, context, askedBy: caller, revealing: false)
                        asks.finish(tab: tab.id, token: token, failure: nil, services: services)
                        return fields
                    } catch {
                        asks.finish(tab: tab.id, token: token, failure: (error as? ActionFailure)?.message ?? Self.startFailure(error, name: named, id: request.machineID ?? named, agent: request.agent), services: services)
                        throw error
                    }
                }
            }
        }
    }

    /// A new machine can take longer than `action.run`'s person deadline to come up: the run then
    /// answers `pending` (the work goes on, and the session's tab opens in the machine's workspace).
    static let answerWithin: Duration = ActionDescriptor.personDeadline - .seconds(10)

    static func pending(_ request: Request) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["pending": .bool(true), "agent": .string(request.agent), "text": .string(CloudStartSessionStrings.stillStarting)]
        if let id = request.machineID { fields["machine_id"] = .string(id) }
        if let name = request.name { fields["machine_name"] = .string(name) }
        return fields
    }

    /// The chat tab of agent session `session` on any machine: a chat on this Mac, or one on a
    /// Cloud machine (a session this command started there may start another).
    static func chat(_ session: String, services: AppServices) -> TabModel? {
        let tabs = services.agentTabs
        for (workspace, _) in services.machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { (tabs.sessions[tabs.resolve($0.id)] ?? $0.agentSession?.session) == session }) { return tab }
            }
        }
        return nil
    }

    /// The run's arguments, checked: `--agent` is a harness id, `--cwd` an absolute folder.
    static func request(_ invocation: ActionInvocation) throws -> Request {
        let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !agent.isEmpty, agent.utf8.count <= 64, agent.unicodeScalars.allSatisfy(allowed.contains), let first = agent.first, first.isLetter || first.isNumber else {
            throw ActionFailure(message: CloudStartSessionStrings.agentInvalid)
        }
        var cwd = invocation["cwd"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        if cwd?.isEmpty == true { cwd = nil }
        if let cwd, !cwd.hasPrefix("/") || cwd.utf8.count > 4096 || cwd.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw ActionFailure(message: CloudStartSessionStrings.cwdInvalid)
        }
        let machineID = invocation.target.flatMap { $0.kind == .machine ? $0.id : nil }
        let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        return Request(machineID: machineID, name: name?.isEmpty == false ? name : nil, agent: agent, cwd: cwd)
    }

    /// Takes or creates the machine, connects, opens the chat's tab there and starts the session.
    func run(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext, askedBy: String? = nil,
             revealing: Bool = true) async throws -> [String: ActionResultValue] {
        let session = try await machine(request, invocation, askedBy: askedBy)
        let name = session.machine.title, id = session.machineID, agent = request.agent
        try await connected(session, invocation, request)
        let daemon = session.daemon
        guard let host = AgentTabStore.registryHost(of: daemon) else {
            throw ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
        let anchor: (id: String, key: WorkspaceKey, pane: PaneModel)
        do {
            anchor = try await CloudHandlers.terminalAnchor(on: session, context)
        } catch {
            throw ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
        let started: AgentTabRemoteStart.Started
        let tabKey: String
        do {
            let tabs = services.agentTabs
            let pending = try tabs.open(in: anchor.pane.handle, of: daemon, seed: request.cwd.map { AgentPaneSeedSource(AgentPaneSeed(cwd: $0)) })
            tabKey = try await pending.value().key
            // The start reads the tab as the machine's tree lists it.
            _ = await CloudMove.holds(within: .seconds(10)) { [services] in services.locateTab(tabKey) != nil }
            switch tabs.remoteHost(tabKey) {
            case let remote as AgentTabRemoteHost: started = try await remote.startNow(cwd: request.cwd, harness: agent)
            case let refused as AgentTabRefusedHost: throw refused.refusal
            default: throw AgentRemoteStartRefusal.startUnsupported(machine: name)
            }
        } catch {
            throw ActionFailure(message: Self.startFailure(error, name: name, id: id, agent: agent))
        }
        // Where a hook that saves the session's trajectory off the machine (hq#4381) would go, once
        // acpmux has one: the session started, so its id is known here. None exists on base yet.
        if revealing, invocation.allowsViewChange { CloudHandlers.show(anchor.id, context) }
        return [
            "machine_id": .string(id), "machine_name": .string(name), "target": .string("machine:\(id)"),
            "session_id": .string(started.session), "host": .string(host), "agent": .string(agent),
            "workspace_id": .string(anchor.id), "surface_id": .string(String(started.surface)), "tab_id": .string(tabKey),
        ]
    }

    /// The start's refusal in the run's words: the machine is up, its agent is not.
    static func startFailure(_ error: any Error, name: String, id: String, agent: String) -> String {
        if let refusal = error as? AgentRemoteStartRefusal {
            switch refusal.code {
            case AgentRemoteStartRefusal.folderNeededCode, "agent_session.home_unconfirmed", "agent_session.above_home":
                return CloudStartSessionStrings.needsFolder(name, id: id, agent: agent)
            default:
                return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: Self.reason(refusal.userMessage))
            }
        }
        let reason = (error as? AgentTabRefusal)?.message ?? (error as? ActionFailure)?.message ?? String(describing: error)
        return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: Self.reason(reason))
    }

    /// `text` as one shell word: as it is when it is a plain name, else in single quotes.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard text.isEmpty || !text.unicodeScalars.allSatisfy(plain.contains) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A refusal sentence inside the run's parentheses: no closing period.
    static func reason(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The machine named by id, else by name, else a new one with that name.
    private func machine(_ request: Request, _ invocation: ActionInvocation, askedBy: String?) async throws -> CloudMachineSession {
        let machines = services.machines
        if let id = request.machineID {
            guard let session = machines.session(id) else { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
            return session
        }
        let name = request.name ?? ""
        if let named = machines.cloud.first(where: { $0.machine.title == name }) { return named }
        do {
            return try await services.cloud.createMachine(name: name, startedByPerson: invocation.origin == .user, askedBy: askedBy ?? invocation.callerAgentSession)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let detail = (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
            throw ActionFailure(message: CloudStartSessionStrings.createFailed(name, quoted: Self.shellQuoted(name), agent: request.agent, reason: Self.reason(detail)))
        }
    }

    /// The machine connected with its store's id: a paused one resumes, a new one comes up. Nothing
    /// here waits on a client snapshot (hq#4381): the machine's own acpmux keeps its sessions.
    private func connected(_ session: CloudMachineSession, _ invocation: ActionInvocation, _ request: Request) async throws {
        let failure = { ActionFailure(message: CloudStartSessionStrings.notConnected(session.machine.title, id: session.machineID, agent: request.agent)) }
        if session.daemon.connection == nil {
            await session.refreshIfMaybePaused()
            let origin = CloudHandlers.connectOrigin(for: invocation)
            if session.machine.status == .paused { session.attach(origin: origin) } else { session.connect(origin: origin) }
        }
        let daemon = session.daemon
        guard await CloudMove.holds(within: Self.connectWait, until: {
            session.resumeFailure != nil || (daemon.connection != nil && AgentTabStore.registryHost(of: daemon) != nil)
        }) else { throw failure() }
        if session.resumeFailure != nil { throw failure() }
    }

    /// How long a machine has to come up (Move to Cloud's own wait).
    static let connectWait: Duration = .seconds(180)
}
