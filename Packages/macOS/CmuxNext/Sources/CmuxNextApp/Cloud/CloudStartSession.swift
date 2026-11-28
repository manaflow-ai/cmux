import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
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

    typealias Request = CloudStartSessionRequest

    static func bind(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let services = context.services
        CloudHandlers.bind(action, registry, reason: reason) { invocation in
            var request = try Self.request(invocation)
            let start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
            // An agent's or the CLI's chat on a machine whose computer the person holds waits until they give it back.
            if let held = request.machineID ?? request.name.flatMap({ name in services.machines.cloud.first(where: { $0.machine.title == name })?.machineID }) {
                if let refusal = services.cloud.computerControl.heldRefusal(invocation, machine: held) { throw ActionFailure(message: refusal) }
            }
            guard !Self.isAgent(invocation) else { return try Self.agentAsk(request, invocation, context) }
            // A person's palette or menu run without a machine means the one they look at.
            if request.machineID == nil, request.name == nil, CloudHandlers.origin(of: invocation) == .user {
                request.machineID = try CloudHandlers.machine(invocation, context).machineID
            }
            if request.machineID == nil, request.name == nil, request.agent != "claude" { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
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

    /// An agent's run: a card in its own chat, and only the person's Start starts anything.
    private static func agentAsk(_ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let services = context.services, start = CloudStartSession(services: services), runs = services.cloud.startSessionRuns
        guard request.machineID != nil || request.name != nil || request.agent == "claude" else { throw ActionFailure(message: CloudStartSessionStrings.needsMachine(agent: request.agent)) }
        let shown = request.machineID.flatMap { services.machines.session($0)?.machine.title }
        if let id = request.machineID, shown == nil { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
        let named = shown ?? request.name ?? "Cloud"
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
        let exists = shown != nil || request.name == nil || services.machines.cloud.contains { $0.machine.title == named }
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
                        // The account the agent asked in: a switch while the card was open refuses. `capCard`: the card's Start is the person's click, so its create may go direct.
                        let fields = try await start.run(request, asPerson, context, account: key.account, byPerson: true, capCard: true, askedBy: caller, revealing: false)
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
        do { return try Request.parse(invocation) { try Self.fromFolder($0, cwd: $1) } }
        catch let refusal as Request.Refusal { throw ActionFailure(message: refusal.message) }
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

    private func recorded(_ original: Request, _ invocation: ActionInvocation, _ context: AppActionContext, account: [String?], byPerson: Bool, capCard: Bool, askedBy: String?,
                          revealing: Bool) async throws -> [String: ActionResultValue] {
        let still = { [services] (machine: String) throws in try Self.checked(account, now: services.cloud.account, original.asked(machine: machine)) }
        try still(original.name ?? original.machineID ?? "")
        let request: Request, cloud = services.cloud
        do {
            request = try await original.preflight(setup: cloud.setup, scheme: services.linkScheme, refreshNamed: {
                try await original.requireFreshNamedList(isFresh: { cloud.hasCurrentList(within: Self.listFresh) }, refresh: { _ = await cloud.refresh() }, check: { try still(original.destinationName) })
            }, heldRefusal: { cloud.computerControl.heldRefusal(invocation, machine: $0) })
        } catch let refusal as Request.Refusal { throw ActionFailure(message: refusal.message) }
        try still(request.name ?? request.machineID ?? "")
        if let local = request.fromFolder, let refused = await services.cloud.move.refusedSource(local, home: NSHomeDirectory(), acpmuxHome: QuitAgents.environment(services)?.home.path, message: { Self.message($0, folder: local) }) { throw ActionFailure(message: refused) } // before any machine
        if let local = request.fromFolder, let cli = services.cloud.move.cli { do { _ = try await CloudMoveCLI(binary: cli).startChatSize(local: local) } catch let refusal as CloudMoveCLI.StartChatPreflightRefusal { throw ActionFailure(message: refusal.message) } } // past the copy's limits, or past the largest machine
        let steps = CloudStartSteps(logger: services.cloud.logger)
        let gateway = services.cloud.gateway.onlineBeside(within: .seconds(10)) { [setup = services.cloud.setup, agent = request.agent, model = request.model] in await setup.choose(harness: agent, model: model, account: nil) } // No login step: only the first turn needs this Mac's gateway, so it comes up beside the steps; a chat its connection, the organization's key or another gateway of the person's serves waits for none (PersonalGateway.servedElsewhere)
        let (session, made) = try await machine(request, invocation, account: account, byPerson: byPerson, capCard: capCard, askedBy: askedBy)
        steps.done("machine") // the list read and the take, or the create's answer
        return try await releasing(made: made, name: session.machine.title, id: session.machineID, account: account, delete: { [services] in try await services.cloud.deleteMachine(session.machineID) }) {
            try await started(on: session, made: made, request, invocation, context, account: account, byPerson: byPerson, revealing: revealing, steps: steps, gateway: gateway)
        }
    }

    /// The start's steps once its machine is chosen: the connect, the copy, the chat's tab and the session's start.
    func started(on session: CloudMachineSession, made: Bool, _ request: Request, _ invocation: ActionInvocation, _ context: AppActionContext, account: [String?], byPerson: Bool,
                         revealing: Bool, steps: CloudStartSteps, gateway: CloudStartBeside<Bool>) async throws -> [String: ActionResultValue] {
        let still = { [services] (machine: String) throws in try Self.checked(account, now: services.cloud.account, request.asked(machine: machine)) }
        let name = session.machine.title, id = session.machineID, agent = request.agent
        try still(name)
        if let refusal = services.cloud.computerControl.heldRefusal(invocation, machine: id) { throw ActionFailure(message: refusal) }
        // From the connect until the agent runs, and through its first turn (``CloudStartGate/started(_:)``), the app's automatic update leaves this machine's daemon alone.
        services.cloud.startGate.enter(id)
        defer { services.cloud.startGate.leave(id) }
        let setup = services.cloud.setup, daemon = session.daemon
        let chatKey = "cloud-start-session-" + UUID().uuidString.lowercased()
        // The keyed restart leaves the tab's cmux-tui running. Prepare approvals beside the
        // connect on a claimed spare, then create the unbound tab beside the restart when supported.
        let preparation = made ? AgentPaneRemoteApprovals.Preparation.daemonSaidSafe : .checkStatus
        let (copy, early, choice, capability) = try await RemoteApprovalPreparations.owned(
            early: !made && daemon.connection != nil,
            connect: {
                try await connected(session, request, account: account, byPerson: byPerson)
                steps.done("connect")
                try still(name)
            },
            prepare: { [services] early in
                await services.cloud.restartWithApprovalsIfIdle(session, preparation, proceed: { account == services.cloud.account }, cacheBusy: !early)
            }
        ) { () async throws -> ((chat: String, trusted: Bool)?, OpenedChat?, CloudSetup.Choice, String?) in
            let (choice, refusal) = await request.launchReadiness(setup: setup, machine: id)
            if choice == .localOnly { throw ActionFailure(message: AgentPaneCloudStart.localOnlyMessage) }
            if let refusal { throw ActionFailure(message: request.setupRequired(refusal, scheme: services.linkScheme, machine: id)) }
            let connection = await setup.launchConnection(choice.connectionID)
            let capability = choice.claudeAuth?.capability ?? connection.map {
                AgentSessionAttachClient.credentialsCapability(harness: agent, nativeKey: $0.endpointCredentials == true, subscription: $0.subscriptionCredentials == true)
            }
            try still(name)
            let folder = try await copiedIfAsked(request, to: session, account: account)
            steps.done("copy")
            if let capability, !daemon.supports(capability) { return (folder, nil, choice, capability) }
            let opened = try await openChat(on: session, request, account: account, byPerson: byPerson, cwd: folder?.chat ?? request.cwd, chatKey: chatKey)
            steps.done("anchor")
            return (folder, opened, choice, capability)
        }
        let cwd = copy?.chat ?? request.cwd
        try still(name)
        steps.done("approvals")
        if let capability, !daemon.supports(capability) {
            await CloudOutdatedMachine.updateBeforeUsingCapability(
                holds: { daemon.supports(capability) },
                update: { [services] in await CloudMachineUpdates.updateNow(id, services: services) }
            )
        }
        try still(name)
        guard let host = AgentTabStore.registryHost(of: session.daemon) else {
            throw ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
        let chat: OpenedChat
        if let early { chat = early } else { chat = try await openChat(on: session, request, account: account, byPerson: byPerson, cwd: cwd, chatKey: chatKey); steps.done("anchor") }
        let anchor = chat.anchor, opened = chat.tab
        try still(name)
        let started: AgentTabRemoteStart.Started, tabKey = opened.key
        do {
            let tabs = services.agentTabs; services.cloud.agentCredentials.use(choice: choice, chat: tabKey, machine: id, harness: agent, claudeAuth: choice.claudeAuth)
            await Self.trust(copy, surface: opened.surface.rawValue, on: session) // before the start, as the composer's: it refuses an untrusted folder
            let credentials = services.cloud.agentCredentials, logger = services.cloud.logger, model = request.model
            CloudAgentPrewarm.begin(cwd: cwd, harness: agent, model: model, mode: nil,
                                    supports: { choice.claudeAuth == nil && daemon.supports($0) }, surface: opened.surface.rawValue,
                                    endpoint: AgentTabRemoteHost.endpoint(on: daemon), ownerLink: CloudMachineLinks(appLink: session.appLink).ownerLink,
                                    permissionMode: tabs.startPermissionMode(), credentials: {
                guard account == services.cloud.account else { throw CancellationError() }
                let credential = try await (choice.connectionID != nil
                    ? credentials.launchCredential(for: choice, harness: agent, model: model)
                    : credentials.launchCredential(chat: opened.key, machine: id, harness: agent, model: model))
                guard account == services.cloud.account else { throw CancellationError() }
                return credential.map { .init(env: $0.env, endpoint: $0.endpoint, harness: $0.harness, model: $0.model ?? model) }
            }) { logger.info("cloud start-session prewarm: \($0, privacy: .public)") }
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
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), AgentRemoteStartRefusal.untrustedCopy(error, of: copy?.trusted == false ? request.fromFolder : nil)?.userMessage ?? Self.startFailure(error, name: name, id: id, agent: agent))
        }
        steps.done("start"); services.cloud.startGate.started(id)
        _ = await gateway.awaited(marking: "gateway", on: steps, if: choice != .claudeMachineLogin && PersonalGateway.turnNeedsIt(credential: choice.connectionID)) // up before the first turn; 0 ms when it came up beside the steps, or when the turn goes straight to the provider
        CloudStartStepRecord.current?.machine = started.phases
        // The session runs now; the result reports it. A switch during the start shows nothing. (A trajectory hook, hq#4381, goes here.)
        if revealing, invocation.allowsViewChange, account == services.cloud.account { CloudHandlers.show(anchor.id, context) }
        // The team sees the new chat now (TeamDO `team.cloud.session.publish`), not on its tab's next change.
        services.cloudTeam.chatStarted()
        return [
            "machine_id": .string(id), "machine_name": .string(name), "target": .string("machine:\(id)"),
            "session_id": .string(started.session), "host": .string(host), "agent": .string(agent),
            "workspace_id": .string(anchor.id), "surface_id": .string(String(started.surface)), "tab_id": .string(tabKey),
            // Where the start's time went (cmuxterm-hq#8658): `cmux cloud start-chat` lists it under its step.
            "stages_ms": .array(steps.recorded.map { .object(["step": .string($0.step), "ms": .int(Int($0.ms))]) }),
        ]
    }

    /// The start's chat on its machine: its workspace and tab (opened, or with `chatKey` found again on a relink).
    typealias OpenedChat = (anchor: (id: String, key: WorkspaceKey, pane: PaneModel), tab: (key: String, surface: SurfaceID))

    /// Opens the start's own chat on `session` in `cwd`: its own workspace, the chat its only tab (CloudMachineWorkspace.chatTab), no terminal.
    /// It runs beside the keyed restart of the machine's acpmux (``started(on:made:_:_:_:account:byPerson:revealing:steps:gateway:)``): it touches cmux-tui alone.
    private func openChat(on session: CloudMachineSession, _ request: Request, account: [String?], byPerson: Bool, cwd: String?, chatKey: String) async throws -> OpenedChat {
        let name = session.machine.title, id = session.machineID, agent = request.agent, daemon = session.daemon
        do {
            let made = try await CloudWait.relinkedOnce(epoch: { session.daemon.store.connectionEpoch }, held: session.linkHeld, relink: { guard (try? await connected(session, request, account: account, byPerson: byPerson)) != nil else { return false }; return await CloudMachineWorkspace.live(session.daemon.store, within: Self.connectWait) }) { [services] in
                try Self.check(account, now: services.cloud.account, request.asked(machine: name)); let open = { (workspace: WorkspaceHandle) in try await services.agentTabs.openFirstPage(workspace: workspace, cwd: cwd, on: daemon, source: AgentPaneSeedSource(AgentPaneSeed(cwd: cwd)), mutationID: chatKey) }
                return try await CloudMachineWorkspace.chatTab(tabKey: chatKey, in: daemon.store, notConnected: ActionFailure(message: CloudStartSessionStrings.notConnected(name, id: id, agent: agent)), anchor: { await CloudHandlers.mirroredAnchor(id: $0, on: session) }, open: open) { key in
                    _ = try await services.machines.local.connection?.pinWorkspaceBeforeCreate(session: daemon.store.registryID, key: key, to: services.machines.local.store.profile(services.windows.active?.state.profileID ?? .defaultProfile)?.id) // listed in the active window's profile
                    guard let connection = daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }; return try await WorkspaceCreation.createWithFirstTab(key, name: nil, on: connection, repair: services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)) { try await open($0.workspace) }
                }
            }
            return (made.anchor, made.tab)
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), CloudStartSessionStrings.notConnected(name, id: id, agent: agent))
        }
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
        let refusal = error as? AgentRemoteStartRefusal
        if let refusal, refusal.code == AgentRemoteStartRefusal.connectionKeyRefusedCode { return refusal.userMessage }
        if let refusal, refusal.code == "agent_session.refused", refusal.reason == "route.settings_secret" { return CloudStartSessionStrings.claudeSettingsSecret }
        let message = refusal?.userMessage ?? (error as? AgentTabRefusal)?.message ?? (error as? ActionFailure)?.message ?? String(describing: error)
        switch (CloudStartCore().launchFailure(code: refusal?.code, message: message, folderNeeded: AgentRemoteStartRefusal.folderNeededCode, named: CloudStartSessionStrings.namedRefusals), refusal) {
        case (.needsFolder, _): return CloudStartSessionStrings.needsFolder(name, id: id, agent: agent)
        case (.named(let code), let refusal?): // never "its agent didn't (agent_session.refused)" (hq#11225)
            return CloudStartSessionStrings.namedRefusal(code, name, id: id, agent: agent, agentName: refusal.agentName ?? agent.chiefHarnessName, expired: refusal.signInExpired, harness: refusal.harness ?? agent)
        case (.failed(let reason), _): return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: reason)
        case (.named, nil): return CloudStartSessionStrings.agentFailed(name, id: id, agent: agent, reason: CloudStartCore.reason(message))
        }
    }

    /// `body`, the start past its machine. A failure that strands the start (``CloudMoveCLI/StartChatPlan/strands(_:)``) on a
    /// machine this run made (`made`), in the account that asked, deletes that machine; a delete that fails says how to.
    func releasing<T>(made: Bool, name: String, id: String, account: [String?], delete: () async throws -> Void, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let ended {
            guard made, CloudMoveCLI.StartChatPlan.strands(ended), account == services.cloud.account else { throw ended }
            do { try await delete() } catch {
                let kept = CloudStartSessionStrings.newMachineKept(name, id: id), failure = ended as? ActionFailure
                throw ActionFailure(message: (failure?.message ?? CloudStrings.errorText(ended)) + " " + kept, isNotFound: failure?.isNotFound ?? false, isQuiet: failure?.isQuiet ?? false)
            }
            throw ended
        }
    }

    /// How recent the machine list must be before `--name` takes or creates a machine.
    static let listFresh: Duration = .seconds(15)

    /// The machine named by id, else by name, else a new one with that name.
    private func machine(_ request: Request, _ invocation: ActionInvocation, account: [String?], byPerson: Bool, capCard: Bool, askedBy: String?) async throws -> (machine: CloudMachineSession, made: Bool) { // made: by this run's own creation (CloudStartRuns.creatingOwn), so nobody's agent runs there yet
        let machines = services.machines
        let cloud = services.cloud
        if let id = request.machineID {
            // Only a machine of the list read for this account now: after a team switch the previous team's stay until it lands.
            if !cloud.hasLoadedCurrentMachines { await cloud.refresh() }
            try Self.checked(account, now: cloud.account, request.asked(machine: id))
            guard cloud.hasLoadedCurrentMachines else { throw ActionFailure(message: CloudStartSessionStrings.targetUnread(request.asked(machine: id))) }
            guard cloud.listedMachineIDs.contains(id), let session = machines.session(id) else { throw ActionFailure(message: CloudStartSessionStrings.noSuchMachine(id: id, agent: request.agent)) }
            return (session, false)
        }
        let name = request.destinationName
        let still = { try Self.check(account, now: cloud.account, request.asked(machine: name)) }
        do {
            let named = try await request.freshNamedMachine(isFresh: { cloud.hasCurrentList(within: Self.listFresh) }, refresh: { _ = await cloud.refresh() }, check: still) { name in
                machines.cloud.first { cloud.listedMachineIDs.contains($0.machineID) && $0.machine.title == name }
            }
            if let named { return (named, false) }
            return try await cloud.startSessionRuns.creatingOwn(name, account: account) { [machines] in
                // Another ask's creation may have ended first.
                if let named = machines.cloud.first(where: { cloud.listedMachineIDs.contains($0.machineID) && $0.machine.title == name }) { return (named, false) }
                try still()
                // The answer of a create asked in another account never joins this one's list.
                return (try await cloud.createMachine(name: name, startedByPerson: byPerson, ownCreate: capCard && invocation.isPersonsOwnRun && ActionRunScope.isPersonsAction(), capCard: capCard, askedBy: askedBy ?? invocation.callerAgentSession, proceed: still), true)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let refusal as Request.Refusal {
            throw ActionFailure(message: refusal.message)
        } catch let changed as AccountChanged {
            throw changed.failure
        } catch {
            let detail = CloudSizeLocked.of(error).flatMap(CloudStartSessionStrings.sizeLocked) ?? (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error) // a size the plan lacks names it and its upgrade
            try Self.failed(account, now: cloud.account, request.asked(machine: name),
                            CloudStartSessionStrings.createFailed(name, quoted: CloudStartCore.shellQuoted(name), agent: request.agent, reason: CloudStartCore.reason(detail)))
        }
    }

    /// The machine connected with its store's id: a paused one resumes, a new one comes up. Nothing
    /// here waits on a client snapshot (hq#4381): the machine's own acpmux keeps its sessions.
    private func connected(_ session: CloudMachineSession, _ request: Request, account: [String?], byPerson: Bool) async throws {
        try await connected(session, byPerson: byPerson, checking: {
            try Self.checked(account, now: services.cloud.account, request.asked(machine: session.machine.title))
        }, failure: ActionFailure(message: CloudStartSessionStrings.notConnected(session.machine.title, id: session.machineID, agent: request.agent)))
    }

    /// Prepares the same live daemon link for a Cloud chat or Settings sign-in.
    func connected(_ session: CloudMachineSession, byPerson: Bool, checking check: () throws -> Void,
                   failure: @autoclosure () -> any Error) async throws {
        let steps = CloudStartSteps(logger: services.cloud.logger)
        try check()
        // A machine that is resuming is waited for (within the start's own connect wait), never refused at once.
        try await CloudHandlers.requireAttachableState(session, waitingOutResume: Self.connectWait)
        try check()
        steps.done("connect.ready") // a resuming machine's resume
        if session.daemon.connection == nil {
            await session.refreshIfMaybePaused()
            try check()
            try await CloudHandlers.requireAttachableState(session, waitingOutResume: Self.connectWait)
            // The resume or connect below changes the machine: only for the account that asked.
            try check()
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
        try check()
        guard up else { throw failure() }
    }

    /// How long a machine has to come up (Move to Cloud's own wait).
    static let connectWait: Duration = .seconds(180)
}
