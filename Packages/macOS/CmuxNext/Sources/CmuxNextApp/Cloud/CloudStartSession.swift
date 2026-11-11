import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSettings
import Foundation

/// `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): one call takes a Cloud
/// machine (`--target machine:<id>`, or `--name`, created when no machine has that name), starts
/// an agent session in that machine's own acpmux, and answers `{machine_id, session_id, host}`.
///
/// The session starts the way a new chat in that machine's workspace starts at its first send: a
/// chat tab on the machine's store (`registry:<id>` host), then `agent-session-start` through the
/// machine's daemon, with this app's key when the machine takes it (``AgentTabRemoteHost/startNow``).
/// The chat's tab stays in the machine's first workspace, so the person can open it. With `--from-folder`,
/// it starts in a copy of that folder on this Mac, copied as the composer's Cloud start copies one (``copied(_:to:_:account:)``).
///
/// An agent's run (the cmux MCP server, or a shell naming its chat) starts the machine and the
/// session as the person's own would, asking nobody (`cloud.agentsStartWithoutAsking`, on by
/// default; Leo, 2026-11-03: "shouldn't have needed to ask me"). Only the Cloud plan's own limits
/// refuse it (the server's answer to the create). With that setting off, it asks the person with a
/// card in its own chat (Start, Not now) like an agent's Move to Cloud (``CloudMoveAsks``), and only
/// the person's Start (on the card, or `cmux agents dialog answer` from their own terminal,
/// ``CloudAskDialogs``) starts it; the run then answers `pending` with the dialog's id as soon as
/// the card shows, and the same command again waits for the answer.
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
        /// A folder on this Mac (`--from-folder`) the session starts in a copy of, never with ``cwd``; and `--model`, the agent's model there (nil: its harness default).
        var fromFolder: String?, model: String? // nil unless given: a struct's optional var defaults to nil in its memberwise init (lint forbids `= nil`)
        var login = CloudHarnessLoginAsk() // `--login` and whether a prompt may show (+Login); not in ``command``

        /// The command that asks for this again, every word as the shell reads it back.
        var command: String {
            var words = ["cmux cloud start-session"]
            if let machineID { words.append("--target machine:" + CloudStartCore.shellQuoted(machineID)) } else { words.append("--name " + CloudStartCore.shellQuoted(name ?? "")) }
            words.append("--agent " + agent + (model.map { " --model " + CloudStartCore.shellQuoted($0) } ?? ""))
            if let cwd { words.append("--cwd " + CloudStartCore.shellQuoted(cwd)) }
            if let fromFolder { words.append("--from-folder " + CloudStartCore.shellQuoted(fromFolder)) }
            if let choice = login.requested { words.append("--login " + choice.rawValue) }
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
                    let delegated = CloudAgentStartSetting().delegated(in: services.settings?.snapshot.root ?? .object([:]))
                    return try await start.run(request, invocation, context, account: key.account,
                                               byPerson: CloudStartCore().startsAsPerson(byPerson: CloudHandlers.origin(of: invocation) == .user, delegated: delegated), capCard: CloudHandlers.origin(of: invocation) == .user)
                }
            }
        }
    }

    /// Whether the run is an agent's: a cmux MCP run (by its outermost caller, ``ActionRunScope``),
    /// or one naming the agent chat that sent it.
    static func isAgent(_ invocation: ActionInvocation) -> Bool {
        CloudMoveAsks.isAgent(invocation) || CloudHandlers.origin(of: invocation) == .mcp
    }

    /// Whether the run is the person's own, the only kind whose `--login` is kept or counts as their
    /// consent: a gesture in this app (``ActionInvocation/isPersonsOwnRun``, so never the control
    /// socket claiming `user`). A CLI run is never one: an agent in a terminal looks like the person
    /// there, so a terminal's `--login pass` counts only when the person chose pass in cmux.
    static func isPersons(_ invocation: ActionInvocation) -> Bool {
        CloudHandlers.origin(of: invocation) == .user && invocation.isPersonsOwnRun
    }

    /// An agent's run: a card in its own chat, and only the person's Start starts anything.
    private static func agentAsk(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let services = context.services, start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
        guard request.machineID != nil || request.name != nil else { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
        let shown = request.machineID.flatMap { services.machines.session($0)?.machine.title }
        if let id = request.machineID, shown == nil { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
        let named = shown ?? request.name ?? ""
        let asked = request.asked(machine: named)
        // As the person's Start would: the person delegated agents' starts (only they set it).
        var asPerson = ActionInvocation(target: invocation.target, arguments: invocation.arguments, origin: .user)
        asPerson.callerAgentSession = nil
        let delegated = CloudAgentStartSetting().delegated(in: services.settings?.snapshot.root ?? .object([:]))
        guard CloudStartCore().agentAsksFirst(delegated: delegated) else {
            let key = CloudStartSessionRuns.Key(request, caller: invocation.callerAgentSession, account: services.cloud.account)
            return CloudHandlers.result("start cloud session", context) {
                try await runs.answer(key, within: Self.answerWithin, pending: Self.pending(request, services), forgotten: ActionFailure(message: CloudStartSessionStrings.accountChanged(asked))) {
                    try await start.run(request, asPerson, context, account: key.account, byPerson: true, capCard: false, askedBy: invocation.callerAgentSession, revealing: false)
                }
            }
        }
        guard let caller = invocation.callerAgentSession, let tab = Self.chat(caller, services: services) else {
            throw ActionFailure(message: CloudStartSessionStrings.notInChat(asked))
        }
        let exists = shown != nil || services.machines.cloud.contains { $0.machine.title == named }
        let asks = services.cloud.startSessionAsks
        let text = exists ? CloudStartSessionStrings.ask(agent: request.agent, machine: named) : CloudStartSessionStrings.askNew(agent: request.agent, machine: named)
        // The person's Start is the gesture: the machine is created as theirs, at the agent's ask.
        // The same ask again (the agent's run answered pending) joins the one that runs, and waits.
        let key = CloudStartSessionRuns.Key(request, caller: caller, account: services.cloud.account)
        CloudHandlers.result("start cloud session", context) {
            try await runs.answer(key, within: Self.answerWithin, pending: Self.pending(request, services), forgotten: ActionFailure(message: CloudStartSessionStrings.accountChanged(asked)),
                                  early: true) {
                    let cloud = services.cloud
                    // The card shows: the agent's run answers now, never waiting in silence.
                    let token = try await asks.ask(tab: tab.id, text: text, asked: asked, account: key.account, now: { cloud.account }, caller: caller) { dialog in
                        runs.asking(key, Self.askPending(request, machine: named, dialog: dialog))
                    }
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

    static func askPending(_ request: Request, machine: String, dialog: String) -> [String: ActionResultValue] {
        CloudAskDialog(id: dialog).pending(agent: request.agent, text: CloudStartSessionStrings.askPending(request.asked(machine: machine), dialog: dialog),
                                           machineID: request.machineID, machineName: request.name)
    }

    /// The chat tab of agent session `session` on any machine: a chat on this Mac, or one on a
    /// Cloud machine (a session this command started there may start another).
    static func chat(_ session: String, services: AppServices) -> TabModel? {
        let tabs = services.agentTabs
        for (workspace, _) in services.machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { (tabs.sessions[tabs.tabKey(of: $0)] ?? $0.agentSession?.session) == session }) { return tab }
            }
        }
        return nil
    }

    /// The run's arguments, checked: `--agent` is a harness id, `--cwd` an absolute folder, `--from-folder` one on this Mac.
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
        let login: CloudHarnessLoginAsk
        do { login = try .init(word: invocation["login"]?.stringValue, agent: !isPersons(invocation), prompts: isPersons(invocation)) } catch { throw ActionFailure(message: CloudStartSessionStrings.loginInvalid) }
        return Request(machineID: machineID, name: name?.isEmpty == false ? name : nil, agent: agent, cwd: cwd, fromFolder: try Self.fromFolder(invocation, cwd: cwd), model: invocation["model"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }, login: login) // the machine checks the model
    }

    /// Takes or creates the machine, connects, opens the chat's tab there and starts the session.
    /// `account`: the user and team signed in when it was asked. It is checked before each step
    /// that changes anything and after each wait, so a team switch or sign-out mid-run starts
    /// nothing in the account signed in now.
    /// `byPerson`: the person's own gesture (a palette or menu run, or Start on an agent's card);
    /// it decides how the machine is created and connected. `capCard`: a refusal at the cap opens the cap card, else answers the run.
    /// Its answer's `stages_detail_ms`, beside the top-level `stages_ms`: every step its clocks marked, sub-steps too
    /// (``CloudStartStepRecord``), the machine's own start phases and the run's total.
    func run(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext, account: [String?], byPerson: Bool, capCard: Bool = true, askedBy: String? = nil,
             revealing: Bool = true) async throws -> [String: ActionResultValue] {
        let (answer, record) = try await CloudStartStepRecord.recording { try await recorded(request, invocation, context, account: account, byPerson: byPerson, capCard: capCard, askedBy: askedBy, revealing: revealing) }
        return answer.merging(["stages_detail_ms": .object(["steps": .array(record.steps.map { .object(["step": .string($0.name), "ms": .int($0.ms)]) }), "total": .int(record.total),
                                                            "machine": record.machine.map { .object($0.mapValues { .int($0) }) } ?? .null])]) { $1 }
    }

    private func recorded(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext, account: [String?], byPerson: Bool, capCard: Bool, askedBy: String?,
                          revealing: Bool) async throws -> [String: ActionResultValue] {
        let still = { [services] (machine: String) throws in try Self.checked(account, now: services.cloud.account, request.asked(machine: machine)) }
        try still(request.name ?? request.machineID ?? "")
        if let local = request.fromFolder, case .failure(let r) = await AgentPaneCloudStart.checkedFolder(local, home: NSHomeDirectory()) { throw ActionFailure(message: Self.message(r, folder: local)) } // before any machine
        let steps = CloudStartSteps(logger: services.cloud.logger)
        let session = try await machine(request, invocation, account: account, byPerson: byPerson, capCard: capCard, askedBy: askedBy)
        steps.done("machine") // the list read and the take, or the create's answer
        let name = session.machine.title, id = session.machineID, agent = request.agent
        try still(name)
        // From the connect until the agent runs, the app's automatic update leaves this machine's daemon alone.
        services.cloud.startGate.enter(id)
        defer { services.cloud.startGate.leave(id) }
        try await connected(session, request, account: account, byPerson: byPerson)
        steps.done("connect")
        try still(name)
        async let anchored = self.anchor(session, request, context, account: account, byPerson: byPerson) // beside the copy and the login: the tab waits on all three
        async let copied = copiedIfAsked(request, to: session, account: account)
        // Remote approvals turn on beside the login (an idle daemon only), awaited on every exit: the gate is never released under them.
        try await RemoteApprovalPreparations.owned({ [services] in await services.cloud.restartWithApprovalsIfIdle(session, .checkStatus) { account == services.cloud.account } }) {
            try await passHarnessLogin(session, agent: agent, login: request.login) { try still(name) }
            steps.done("login")
        }
        steps.done("approvals")
        let copy = try await copied, cwd = copy?.chat ?? request.cwd // before the session starts in it; the account is checked again past the anchor
        if let refusal = session.harnessLogin?.refusal { throw ActionFailure(message: CloudStartSessionStrings.loginRefused(Self.loginRefusal(refusal), request.asked(machine: name))) }
        guard let host = AgentTabStore.registryHost(of: session.daemon) else { throw ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent)) }
        let (found, foundEpoch) = try await anchored // the copy (an older daemon's update) or the login may have relinked since: its pane is the old link's, so find it again
        let anchor = if session.daemon.store.connectionEpoch == foundEpoch { found } else { try await self.anchor(session, request, context, account: account, byPerson: byPerson).0 }
        steps.done("anchor")
        try still(name)
        let started: AgentTabRemoteStart.Started, tabKey: String
        do {
            let tabs = services.agentTabs
            let pending = try tabs.open(in: anchor.pane.handle, of: session.daemon, seed: cwd.map { AgentPaneSeedSource(AgentPaneSeed(cwd: $0)) })
            let opened = try await Self.created(pending, name: name, id: id, agent: agent); tabKey = opened.key
            await Self.trust(copy, surface: opened.surface.rawValue, on: session) // before the start, as the composer's: it refuses an untrusted folder
            // The start reads the tab as the machine's tree lists it (`tabKey` is the store's id); a slow link lists it late, so 60 s, not 10 (a working start failed "not connected").
            let listed = await CloudWait.holds(within: .seconds(60)) { [services] in services.locateTab(tabKey, onMachine: id) != nil }
            try Self.check(account, now: services.cloud.account, request.asked(machine: name))
            guard listed else { throw AccountChanged(failure: ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))) }
            steps.done("tab")
            switch tabs.host(for: tabs.tabKey(tabKey, machine: id)) {
            case let remote as AgentTabRemoteHost:
                // Each restart and start try is for the account that asked, checked right before it.
                let command = request.command, model = request.model
                started = try await Self.starting(name: name, id: id, agent: agent, account: account, now: { services.cloud.account }, asked: request.asked(machine: name)) {
                    try await CloudWait.retriedOnce({ try await remote.startNow(cwd: cwd, harness: agent, model: model) { @MainActor [services] in
                        try Self.check(account, now: services.cloud.account, CloudStartSessionStrings.Asked(machine: name, agent: agent, command: command))
                    } }, closed: CloudWait.linkDropped, relink: { await session.linkUp(within: Self.connectWait) && session.linkHeld() })
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
        steps.done("start")
        CloudStartStepRecord.current?.machine = started.phases
        // The session runs now; the result reports it. A switch during the start shows nothing. (A trajectory hook, hq#4381, goes here.)
        if revealing, invocation.allowsViewChange, account == services.cloud.account { CloudHandlers.show(anchor.id, context) }
        return [
            "machine_id": .string(id), "machine_name": .string(name), "target": .string("machine:\(id)"),
            "session_id": .string(started.session), "host": .string(host), "agent": .string(agent),
            "workspace_id": .string(anchor.id), "surface_id": .string(String(started.surface)), "tab_id": .string(tabKey),
            // Where the start's time went (cmuxterm-hq#8658): `cmux cloud start-chat` lists it under its step.
            "stages_ms": .array(steps.recorded.map { .object(["step": .string($0.step), "ms": .int(Int($0.ms))]) }),
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

    /// A refusal that passes a step's error mapping as it is: the account changed since the ask, or a step's precondition failed.
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
                return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: CloudStartCore.reason(refusal.userMessage))
            }
        }
        let reason = (error as? AgentTabRefusal)?.message ?? (error as? ActionFailure)?.message ?? String(describing: error)
        return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: CloudStartCore.reason(reason))
    }

    /// How recent the machine list must be before `--name` takes or creates a machine.
    static let listFresh: Duration = .seconds(15)

    /// The machine named by id, else by name, else a new one with that name.
    private func machine(_ request: Request, _ invocation: ActionInvocation, account: [String?], byPerson: Bool, capCard: Bool, askedBy: String?) async throws -> CloudMachineSession {
        let machines = services.machines
        let cloud = services.cloud
        if let id = request.machineID {
            // Only a machine of the list read for this account now: after a team switch the previous team's stay until it lands.
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
                let made = try await cloud.createMachine(name: name, startedByPerson: byPerson, capCard: capCard, askedBy: askedBy ?? invocation.callerAgentSession, proceed: still)
                if request.login.allowsEarlyCopy(harness: request.agent) { CloudStartChat.warmSpare(services, claimed: made.machineID) } // the login copy beside the connect, as a start-chat claim's
                return made
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch {
            let detail = (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
            try Self.failed(account, now: cloud.account, request.asked(machine: name),
                            CloudStartSessionStrings.createFailed(name, quoted: CloudStartCore.shellQuoted(name), agent: request.agent, reason: CloudStartCore.reason(detail)))
        }
    }

    /// The workspace and pane the run's tab opens in, found again once on a relink, and the link epoch it was found on; a run whose account changed creates none.
    private func anchor(_ session: CloudMachineSession, _ request: Request, _ context: AppActionContext, account: [String?], byPerson: Bool) async throws -> ((id: String, key: WorkspaceKey, pane: PaneModel), Int) {
        let asked = request.asked(machine: session.machine.title)
        do {
            return (try await CloudWait.relinkedOnce(epoch: { session.daemon.store.connectionEpoch }, held: session.linkHeld, relink: { guard (try? await connected(session, request, account: account, byPerson: byPerson)) != nil else { return false }; return await CloudMachineWorkspace.live(session.daemon.store, within: Self.connectWait) }) { try await CloudHandlers.terminalAnchor(on: session, context) { [services] in try Self.check(account, now: services.cloud.account, asked) } }, session.daemon.store.connectionEpoch) // the epoch read past the wait
        } catch let changed as AccountChanged { throw changed.failure } catch is CancellationError { throw CancellationError() } catch {
            try Self.failed(account, now: services.cloud.account, asked, CloudStartSessionStrings.notConnected(session.machine.title, id: session.machineID, agent: request.agent))
        }
    }

    /// The machine connected with its store's id: a paused one resumes, a new one comes up. Nothing
    /// here waits on a client snapshot (hq#4381): the machine's own acpmux keeps its sessions.
    private func connected(_ session: CloudMachineSession, _ request: Request, account: [String?], byPerson: Bool) async throws {
        let failure = { ActionFailure(message: CloudStartSessionStrings.notConnected(session.machine.title, id: session.machineID, agent: request.agent)) }
        let steps = CloudStartSteps(logger: services.cloud.logger)
        // A machine that is resuming is waited for (within the start's own connect wait), never refused at once.
        try await CloudHandlers.requireAttachableState(session, waitingOutResume: Self.connectWait)
        steps.done("connect.ready") // a resuming machine's resume
        if session.daemon.connection == nil {
            await session.refreshIfMaybePaused()
            try await CloudHandlers.requireAttachableState(session, waitingOutResume: Self.connectWait)
            // The resume or connect below changes the machine: only for the account that asked.
            try Self.checked(account, now: services.cloud.account, request.asked(machine: session.machine.title))
            let origin: CloudLinkOrigin = byPerson ? .user : .script
            if session.machine.status == .paused { session.attach(origin: origin) } else { session.connect(origin: origin) }
            steps.done("connect.resume") // a paused machine's state read and its resume or connect asked
        }
        // An update of this machine already running when the start came (one that begins later finds the start in ``CloudStartGate``)
        // restarts the daemon: the agent starts once it ended and the link is back, and holds.
        let up = await CloudWait.linked(within: Self.connectWait, { await session.linkUp(within: Self.connectWait) }) {
            [policy = services.daemonUpdates.policy, id = CloudMachineUpdateTarget.id(session.machineID)] in await policy.turnRunning(id)
        } && session.linkHeld()
        steps.done("connect.link") // the relay link up and held
        // A sign-out, team switch or cancellation during the wait is that, not a machine that didn't connect.
        try Self.checked(account, now: services.cloud.account, request.asked(machine: session.machine.title))
        guard up else { throw failure() }
    }

    /// The machine takes the person's harness login before the session starts, as a composer start's does (+Login).
    /// The login may wait on a confirm: `still` checks the asking account after it, as after every wait.
    func passHarnessLogin(_ session: CloudMachineSession, agent: String, login: CloudHarnessLoginAsk = .init(), still: () throws -> Void) async throws {
        _ = await CloudStartChat(services: services).passHarnessLogin(harness: agent, machine: session, codexPrompt: false, ask: login) // a scripted run never waits on a device code
        try still()
    }
    /// How long a machine has to come up (Move to Cloud's own wait).
    static let connectWait: Duration = .seconds(180)
}
