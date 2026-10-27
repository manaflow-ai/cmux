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

        /// The command that asks for this again, every word as the shell reads it back.
        var command: String {
            var words = ["cmux cloud start-session"]
            if let machineID { words.append("--target machine:" + CloudStartSession.shellQuoted(machineID)) } else { words.append("--name " + CloudStartSession.shellQuoted(name ?? "")) }
            words.append("--agent " + agent)
            if let cwd { words.append("--cwd " + CloudStartSession.shellQuoted(cwd)) }
            return words.joined(separator: " ")
        }

        func asked(machine: String) -> CloudStartSessionStrings.Asked {
            CloudStartSessionStrings.Asked(machine: machine, agent: agent, command: command)
        }
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let services = context.services
        CloudHandlers.bind(action, registry, reason: reason) { invocation in
            var request = try Self.request(invocation)
            let start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
            guard !Self.isAgent(invocation) else { return try Self.agentAsk(request, invocation, context) }
            // A person's palette or menu run without a machine means the one they look at.
            if request.machineID == nil, request.name == nil, CloudHandlers.origin(of: invocation) == .user {
                request.machineID = try CloudHandlers.machine(invocation, context).machineID
            }
            if request.machineID == nil, request.name == nil { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
            let key = CloudStartSessionRuns.Key(request, caller: nil, account: services.cloud.account)
            CloudHandlers.result("start cloud session", context) {
                try await runs.answer(key, within: Self.answerWithin, pending: Self.pending(request, services), forgotten: Self.forgotten(request, services)) {
                    // A person's gesture only as the outermost run's origin says (a script's nested run is not one).
                    try await start.run(request, invocation, context, account: key.account, byPerson: CloudHandlers.origin(of: invocation) == .user)
                }
            }
        }
    }

    /// Whether the run is an agent's: a cmux MCP run (by its outermost caller, ``ActionRunScope``),
    /// or one naming the agent chat that sent it.
    static func isAgent(_ invocation: ActionInvocation) -> Bool {
        CloudMoveAsks.isAgent(invocation) || CloudHandlers.origin(of: invocation) == .mcp
    }

    /// An agent's run: a card in its own chat, and only the person's Start starts anything.
    private static func agentAsk(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let services = context.services, start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
        guard request.machineID != nil || request.name != nil else { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
        let shown = request.machineID.flatMap { services.machines.session($0)?.machine.title }
        if let id = request.machineID, shown == nil { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
        let named = shown ?? request.name ?? ""
        let asked = request.asked(machine: named)
        guard let caller = invocation.callerAgentSession, let tab = Self.chat(caller, services: services) else {
            throw ActionFailure(message: CloudStartSessionStrings.notInChat(asked))
        }
        let exists = shown != nil || services.machines.cloud.contains { $0.machine.title == named }
        let asks = services.cloud.startSessionAsks
        let text = exists ? CloudStartSessionStrings.ask(agent: request.agent, machine: named) : CloudStartSessionStrings.askNew(agent: request.agent, machine: named)
        // The person's Start is the gesture: the machine is created as theirs, at the agent's ask.
        var asPerson = ActionInvocation(target: invocation.target, arguments: invocation.arguments, origin: .user)
        asPerson.callerAgentSession = nil
        // The same ask again (the agent's run answered pending) joins the one that runs.
        let key = CloudStartSessionRuns.Key(request, caller: caller, account: services.cloud.account)
        CloudHandlers.result("start cloud session", context) {
            try await runs.answer(key, within: Self.answerWithin, pending: Self.pending(request, services), forgotten: ActionFailure(message: CloudStartSessionStrings.accountChanged(asked))) {
                    let cloud = services.cloud
                    let token = try await asks.ask(tab: tab.id, text: text, asked: asked, account: key.account, now: { cloud.account })
                    asks.show(tab: tab.id, token: token, .working, CloudStartSessionStrings.starting(agent: request.agent, machine: named))
                    do {
                        // The account the agent asked in: a switch while the card was open refuses.
                        let fields = try await start.run(request, asPerson, context, account: key.account, byPerson: true, askedBy: caller, revealing: false)
                        // Nothing is shown on its own (the person is in the asking chat); the card
                        // links to the new chat, and Open Chat, the person's click, shows it.
                        guard case .string(let opened)? = fields["tab_id"] else {
                            asks.finish(tab: tab.id, token: token, failure: nil)
                            return fields
                        }
                        asks.started(tab: tab.id, token: token, text: CloudStartSessionStrings.started(agent: request.agent, machine: named),
                                     gone: CloudStartSessionStrings.chatGone(agent: request.agent, machine: named)) { [weak services] in
                            services?.revealTab(opened) ?? false
                        }
                        return fields
                    } catch is CancellationError {
                        // Only a sign-out or team switch cancels a run (``CloudStartSessionRuns/forgetAll()``).
                        asks.finish(tab: tab.id, token: token, failure: CloudStartSessionStrings.accountChangedWhileStarting(asked))
                        throw CancellationError()
                    } catch {
                        asks.finish(tab: tab.id, token: token, failure: (error as? ActionFailure)?.message ?? Self.startFailure(error, name: named, id: request.machineID ?? named, agent: request.agent))
                        throw error
                    }
            }
        }
    }

    /// A new machine can take longer than `action.run`'s person deadline to come up: the run then
    /// answers `pending` (the work goes on, and the session's tab opens in the machine's workspace).
    static let answerWithin: Duration = ActionDescriptor.personDeadline - .seconds(10)

    /// What a caller still waiting gets when a sign-out or team switch ends the run.
    static func forgotten(_ request: Request, _ services: AppServices) -> ActionFailure {
        let machine = request.machineID.flatMap { services.machines.session($0)?.machine.title } ?? request.name ?? request.machineID ?? ""
        return ActionFailure(message: CloudStartSessionStrings.accountChanged(request.asked(machine: machine)))
    }

    static func pending(_ request: Request, _ services: AppServices) -> [String: ActionResultValue] {
        let machine = request.machineID.flatMap { services.machines.session($0)?.machine.title } ?? request.name ?? request.machineID ?? ""
        var fields: [String: ActionResultValue] = ["pending": .bool(true), "agent": .string(request.agent),
                                                   "text": .string(CloudStartSessionStrings.stillStarting(request.asked(machine: machine)))]
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
    /// `account`: the user and team signed in when it was asked. It is checked before each step
    /// that changes anything and after each wait, so a team switch or sign-out mid-run starts
    /// nothing in the account signed in now.
    /// `byPerson`: the person's own gesture (a palette or menu run, or Start on an agent's card);
    /// it decides how the machine is created and connected.
    func run(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext, account: [String?], byPerson: Bool, askedBy: String? = nil,
             revealing: Bool = true) async throws -> [String: ActionResultValue] {
        let still = { [services] (machine: String) throws in try Self.checked(account, now: services.cloud.account, request.asked(machine: machine)) }
        try still(request.name ?? request.machineID ?? "")
        let session = try await machine(request, invocation, account: account, byPerson: byPerson, askedBy: askedBy)
        let name = session.machine.title, id = session.machineID, agent = request.agent
        try still(name)
        try await connected(session, request, account: account, byPerson: byPerson)
        try still(name)
        let daemon = session.daemon
        guard let host = AgentTabStore.registryHost(of: daemon) else {
            throw ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
        let anchor: (id: String, key: WorkspaceKey, pane: PaneModel)
        do {
            anchor = try await CloudHandlers.terminalAnchor(on: session, context) { [services] in
                try Self.check(account, now: services.cloud.account, request.asked(machine: name))
            }
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
        try still(name)
        let started: AgentTabRemoteStart.Started
        let tabKey: String
        do {
            let tabs = services.agentTabs
            let pending = try tabs.open(in: anchor.pane.handle, of: daemon, seed: request.cwd.map { AgentPaneSeedSource(AgentPaneSeed(cwd: $0)) })
            tabKey = try await Self.created(pending, name: name, id: id, agent: agent).key
            // The start reads the tab as the machine's tree lists it (`tabKey` is the store's id).
            let listed = await CloudMove.holds(within: .seconds(10)) { [services] in services.locateTab(tabKey) != nil }
            try Self.check(account, now: services.cloud.account, request.asked(machine: name))
            guard listed else { throw AccountChanged(failure: ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))) }
            switch tabs.remoteHost(tabKey) {
            case let remote as AgentTabRemoteHost:
                // Each restart and start try is for the account that asked, checked right before it.
                let command = request.command
                started = try await Self.starting(name: name, id: id, agent: agent, account: account, now: { services.cloud.account }, asked: request.asked(machine: name)) {
                    try await remote.startNow(cwd: request.cwd, harness: agent) { @MainActor [services] in
                        try Self.check(account, now: services.cloud.account, CloudStartSessionStrings.Asked(machine: name, agent: agent, command: command))
                    }
                }
            case let refused as AgentTabRefusedHost: throw refused.refusal
            default: throw AgentRemoteStartRefusal.startUnsupported(machine: name)
            }
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), Self.startFailure(error, name: name, id: id, agent: agent))
        }
        // Where a hook that saves the session's trajectory off the machine (hq#4381) would go, once
        // acpmux has one: the session started, so its id is known here. None exists on base yet.
        // The session runs now; the result reports it. A switch during the start shows nothing.
        if revealing, invocation.allowsViewChange, account == services.cloud.account { CloudHandlers.show(anchor.id, context) }
        return [
            "machine_id": .string(id), "machine_name": .string(name), "target": .string("machine:\(id)"),
            "session_id": .string(started.session), "host": .string(host), "agent": .string(agent),
            "workspace_id": .string(anchor.id), "surface_id": .string(String(started.surface)), "tab_id": .string(tabKey),
        ]
    }

    /// The store's tab of the chat this run opened. The person closing it before the store
    /// answered is no account change: the refusal says the tab closed and gives the command.
    static func created(_ pending: AgentTabPending, name: String, id: String, agent: String) async throws -> AgentTabCreated {
        do {
            return try await pending.value()
        } catch is CancellationError where !Task.isCancelled {
            throw AccountChanged(failure: ActionFailure(message: CloudStartSessionStrings.tabClosed(name, id: id, agent: agent)))
        }
    }

    /// The session's start on the machine. Closing the new chat's tab cancels its start
    /// (``AgentTabStore``'s release of the tab): that says the tab closed. The run's own
    /// cancellation stays one, and an ended account says so.
    static func starting(name: String, id: String, agent: String, account: [String?], now: () -> [String?], asked: CloudStartSessionStrings.Asked,
                         _ start: () async throws -> AgentTabRemoteStart.Started) async throws -> AgentTabRemoteStart.Started {
        do {
            return try await start()
        } catch is CancellationError {
            try check(account, now: now(), asked)
            throw AccountChanged(failure: ActionFailure(message: CloudStartSessionStrings.tabClosed(name, id: id, agent: agent)))
        }
    }

    /// A refusal that passes through a step's error mapping as it is: the account changed since
    /// the run was asked, or a step's own precondition failed.
    struct AccountChanged: Error { var failure: ActionFailure }

    /// Inside a step whose other errors are mapped (``AccountChanged`` passes through the mapping).
    static func check(_ account: [String?], now: [String?], _ asked: CloudStartSessionStrings.Asked) throws {
        try Task.checkCancellation()
        guard account == now else { throw AccountChanged(failure: ActionFailure(message: CloudStartSessionStrings.accountChanged(asked))) }
    }

    /// A step's failure as `message`, unless the run was cancelled or its account ended meanwhile:
    /// a wait that ended for that (its own nil or error) is never reported as the step failing.
    static func failed(_ account: [String?], now: [String?], _ asked: CloudStartSessionStrings.Asked, _ message: String) throws -> Never {
        try checked(account, now: now, asked)
        throw ActionFailure(message: message)
    }

    /// Between steps: the refusal itself.
    static func checked(_ account: [String?], now: [String?], _ asked: CloudStartSessionStrings.Asked) throws {
        do { try check(account, now: now, asked) } catch let changed as AccountChanged { throw changed.failure }
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

    /// How recent the machine list must be before `--name` takes or creates a machine.
    static let listFresh: Duration = .seconds(15)

    /// The machine named by id, else by name, else a new one with that name.
    private func machine(_ request: Request, _ invocation: ActionInvocation, account: [String?], byPerson: Bool, askedBy: String?) async throws -> CloudMachineSession {
        let machines = services.machines
        let cloud = services.cloud
        if let id = request.machineID {
            // Only a machine of the list read for the account signed in now: after a team switch,
            // the previous team's machines stay in the store until that list lands.
            if !cloud.hasLoadedCurrentMachines { await cloud.refresh() }
            try Self.checked(account, now: cloud.account, request.asked(machine: id))
            guard cloud.hasLoadedCurrentMachines else { throw ActionFailure(message: CloudStartSessionStrings.targetUnread(request.asked(machine: id))) }
            guard let session = machines.session(id) else { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
            return session
        }
        let name = request.name ?? ""
        // A list the server answered just now for this account: a machine by this name made
        // elsewhere is taken, never made again. A failed or superseded read refuses.
        let still = { try Self.check(account, now: cloud.account, request.asked(machine: name)) }
        if !cloud.hasCurrentList(within: Self.listFresh) { await cloud.refresh() }
        try Self.checked(account, now: cloud.account, request.asked(machine: name))
        guard cloud.hasCurrentList(within: Self.listFresh) else { throw ActionFailure(message: CloudStartSessionStrings.listUnread(request.asked(machine: name))) }
        if let named = machines.cloud.first(where: { $0.machine.title == name }) { return named }
        do {
            return try await cloud.startSessionRuns.creating(name, account: account) { [machines] in
                // Another ask's creation may have ended first.
                if let named = machines.cloud.first(where: { $0.machine.title == name }) { return named }
                try still()
                // The answer of a create asked in another account never joins this one's list.
                return try await cloud.createMachine(name: name, startedByPerson: byPerson, askedBy: askedBy ?? invocation.callerAgentSession, proceed: still)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch {
            let detail = (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
            try Self.failed(account, now: cloud.account, request.asked(machine: name),
                            CloudStartSessionStrings.createFailed(name, quoted: Self.shellQuoted(name), agent: request.agent, reason: Self.reason(detail)))
        }
    }

    /// The machine connected with its store's id: a paused one resumes, a new one comes up. Nothing
    /// here waits on a client snapshot (hq#4381): the machine's own acpmux keeps its sessions.
    private func connected(_ session: CloudMachineSession, _ request: Request, account: [String?], byPerson: Bool) async throws {
        let failure = { ActionFailure(message: CloudStartSessionStrings.notConnected(session.machine.title, id: session.machineID, agent: request.agent)) }
        if session.daemon.connection == nil {
            await session.refreshIfMaybePaused()
            // The resume or connect below changes the machine: only for the account that asked.
            try Self.checked(account, now: services.cloud.account, request.asked(machine: session.machine.title))
            let origin: CloudLinkOrigin = byPerson ? .user : .script
            if session.machine.status == .paused { session.attach(origin: origin) } else { session.connect(origin: origin) }
        }
        let daemon = session.daemon
        let up = await CloudMove.holds(within: Self.connectWait, until: {
            session.resumeFailure != nil || (daemon.connection != nil && AgentTabStore.registryHost(of: daemon) != nil)
        })
        // A sign-out, team switch or cancellation during the wait is that, not a machine that
        // didn't connect.
        try Self.checked(account, now: services.cloud.account, request.asked(machine: session.machine.title))
        guard up, session.resumeFailure == nil else { throw failure() }
    }

    /// How long a machine has to come up (Move to Cloud's own wait).
    static let connectWait: Duration = .seconds(180)
}

extension CloudStartSessionRuns.Key {
    /// The run of `request` asked by chat `caller` (nil: a person's or a script's) in `account`.
    init(_ request: CloudStartSession.Request, caller: String?, account: [String?]) {
        self.init(machine: request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? ""), agent: request.agent, cwd: request.cwd,
                  caller: caller, account: account)
    }
}
