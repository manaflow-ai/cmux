import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextCloudPlace
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

extension CloudHandlers {
    /// Move to Cloud and Bring Back Local: the palette, the tab and chat right-click
    /// menus and `cmux cloud move` / `cmux cloud bring-back` each run one binding
    /// (``CloudMove``, ``CloudBringBack``). An agent's run of either is never a move.
    static func bindMove(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let reason: @MainActor () -> String? = { services.machines.isFeatureDisabled(.cloud) ? RefusalStrings.turnedOffByOrganization : nil }
        // An agent's run asks the person in its chat instead (``CloudMoveAsks``); the card's Move runs this action as theirs.
        services.cloud.toolCards.view = { [weak services] tab, make in make ? services?.agentTabs.view(for: tab) : services?.agentTabs.existingView(tab) }
        // A moved chat's file requests for this Mac ask in that chat (``CloudAccessAsks``).
        services.cloud.accessAsks.start(services: services)
        // A move a quit left unfinished says so in its chat, with Retry (``CloudMoveAsks``).
        services.cloud.moveAsks.offerUnfinished(services: services)
        // Files the person drops or pastes into a moved chat go to its machine (``CloudUploads``); in a
        // chat of an ssh peer's acpmux, to that peer (``AgentPeerUploads``); in a chat on this Mac,
        // files the composer can't attach are saved here (``AgentChatUploads``).
        services.agentTabs.uploader = { [weak services] tab in
            services.flatMap {
                $0.cloud.uploads.uploader(tab: tab, services: $0) ?? AgentPeerUploads.uploader(tab: tab, services: $0)
                    ?? AgentChatUploads.uploader(tab: tab, services: $0)
            }
        }
        services.agentTabs.uploadStager = { [weak services] tab in
            services.flatMap {
                $0.cloud.uploads.stager(tab: tab, services: $0)
                    ?? AgentPeerUploads.stager(tab: tab, services: $0)
                    ?? AgentChatUploads.stager(tab: tab, services: $0)
            }
        }
        // Files dropped or pasted from Finder into a chat on this Mac go as their own paths, never a
        // copy (``AgentPaneDroppedPaths``); a moved or peer chat's still go to its machine. A New Tab page
        // answers as the chat it starts: its tab's record names this Mac's acpmux, or another
        // machine's, whose page model refuses first (``AgentPaneModel/remoteChat``).
        services.agentTabs.localPaths = { [weak services] tab in
            guard let services else { return false }
            return services.cloud.uploads.uploader(tab: tab, services: services) == nil && AgentPeerUploads.target(tab: tab, services: services) == nil
                && services.agentTabs.gitLink?(tab)?.isLocal == true
        }
        bind(CloudMove.action, registry, reason: reason) { invocation in
            if CloudMoveAsks.isAgent(invocation) { return try services.cloud.moveAsks.ask(invocation, services: services) }
            try CloudMove(services: services).start(invocation, context: context)
        }
        bind(CloudBringBack.action, registry, reason: reason) { invocation in
            guard !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: CloudMoveAskStrings.bringBackIsPersons) }
            try CloudBringBack(services: services).start(invocation, context: context)
        }
        bind(CloudTransferLocal.action, registry, reason: reason) { invocation in
            guard !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: CloudMoveAskStrings.bringBackIsPersons) }
            try CloudTransferLocal(services: services).start(invocation, context: context)
        }
        bind(CloudBringBack.toMachine, registry, reason: reason) { invocation in
            guard !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: CloudMoveAskStrings.bringBackIsPersons) }
            try CloudBringBack(services: services).start(invocation, context: context, toMachine: true)
        }
        bindSSHMove(into: registry, context: context)
        // The chat's place controls (cloud/auto/evacuate): Swift calls and draws, Rust decides (``CloudPlaceDriver``).
        // The page runs them on the chat's tab (`action.run`); an agent never moves a chat this way. Auto starts with them.
        let place = services.cloud.placeDriver ?? CloudPlaceDriver(place: services.cloud.place, host: services)
        if services.cloud.placeDriver == nil { services.cloud.placeDriver = place; place.start() }
        for id in [AppServices.placeSet, AppServices.placeRetry, AppServices.placeEvacuate, AppServices.placeCancel, AppServices.placeEvacuateCancel, AppServices.placeBringBackAll] {
            let cancels = id == AppServices.placeCancel || id == AppServices.placeEvacuateCancel
            bind(id, registry, reason: cancels ? { nil } : reason) { invocation in
                guard cancels || !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: CloudMoveAskStrings.bringBackIsPersons) }
                let tab = context.daemonTab(invocation)?.0.id
                switch id {
                case AppServices.placeSet:
                    guard let mode = invocation["mode"]?.stringValue, ["local", "cloud", "auto"].contains(mode) else { throw ActionFailure(message: "mode must be local, cloud or auto") }
                    if let tab { place.setMode(mode, tab: tab, claims: CloudPlaceClaims(invocation)) }
                case AppServices.placeRetry: if let tab { place.retry(tab: tab, claims: CloudPlaceClaims(invocation)) }
                case AppServices.placeCancel: place.cancel(tab: tab, session: invocation["session"]?.stringValue)
                case AppServices.placeEvacuateCancel: place.cancelEvacuation()
                case AppServices.placeBringBackAll: place.bringBackAll(sessions: invocation["sessions"]?.stringValue.map { $0.split(separator: ",").map(String.init) })
                default: place.evacuate(sessions: invocation["sessions"]?.stringValue.map { $0.split(separator: ",").map(String.init) })
                }
            }
        }
        // A chat that cannot move now (no first message yet) shows its rows disabled with why, and every run refuses with it.
        let refusal: @MainActor (ActionInvocation) -> String? = { CloudMove(services: services).refusal($0, context: context) }
        context.setTargetReason(CloudMove.action, refusal)
        ActionTargetTitles.setPaletteReason(CloudMove.action, in: registry) { [weak registry] in registry?.withoutRefusals { refusal(ActionInvocation()) } }
    }

    /// Move to SSH Machine (`agent.moveToMachine`): a started chat to a machine added over SSH, between
    /// two, or back to this Mac, through acpmux's own transfer (``SSHChatMoveRun``; Rust decides the
    /// targets and the call). This reads the chat, runs the move, opens the chat where it went (as a
    /// moved-in chat opens) and closes the old tab, whose chat moved away.
    static func bindSSHMove(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        var moveChoices: [ActionEnumCase] = []
        let previousSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            source == "chatMoveTargets" ? moveChoices : (previousSuggestions?(source) ?? [])
        }
        registry.bindEffect("agent.moveToMachine") { invocation in
            guard !CloudMoveAsks.isAgent(invocation) else { return .refused(SSHChatMoveStrings.personOnly) }
            guard let (tab, _) = context.daemonTab(invocation) else { return .done }
            let key = services.agentTabs.tabKey(of: tab)
            guard let acpmux = QuitAgents.environment(services), var record = services.agentTabs.record(for: key)?.record else { return .refused(SSHChatMoveStrings.failed) }
            record.session = record.session ?? services.agentTabs.sessions[key]
            guard let chat = CloudMoveTargets.chat(record: record, machine: key.machine, services: services) else { return .refused(SSHChatMoveStrings.failed) }
            let target = invocation["machine"]?.stringValue
            let interactive = !registry.isCapturingRefusal && !invocation.viaControlSocket && invocation.origin == .user
            if target == nil && !interactive { return .refused(SSHChatMoveStrings.failed) }
            var pinned = invocation.onMachine(key.machine)
            pinned.target = ActionTargetRef(kind: .tab, id: key.key)
            let options = CloudMoveTargetRules.MoveOptions(
                afterTurn: invocation["afterTurn"]?.boolValue == true,
                interrupt: invocation["interrupt"]?.boolValue == true,
                carryChanges: invocation["carryChanges"]?.boolValue == true,
                leaveDirty: invocation["leaveDirty"]?.boolValue == true,
                dryRun: invocation["dryRun"]?.boolValue == true
            )
            // action-wait-allow: acpmux moves the chat over ssh (another process); where it went is known only once the move answers
            return .waiting(.externalProcess) {
                let peers = ((try? await AcpmuxPeerList(socketPath: acpmux.socketPath).peers()) ?? []).map { CloudMoveTargetRules.Peer(name: $0.name, url: $0.url ?? "") }
                if target == nil {
                    var params: [String: any Sendable] = [:]
                    if case .success(let call) = CloudMoveTargetRules().sshMove(chat, to: "auto", peers: peers),
                       let source = call.source { params["source"] = source }
                    if chat.running != nil { params["sourceKind"] = "cloud" }
                    guard let data = try? await acpmux.catalogCall("_acpmux/move_targets", params: params),
                          let reply = await CloudMoveTargetRules().paletteReply(data) else {
                        return ActionWorkFailure(SSHChatMoveStrings.failed)
                    }
                    moveChoices = reply.targets.filter { $0.reason == nil }.map {
                        ActionEnumCase(value: $0.id, title: $0.label, subtitle: $0.status)
                    }
                    guard registry.ask("agent.moveToMachine", pinned, ActionArgumentAsk(argument: "machine")) else {
                        return ActionWorkFailure(SSHChatMoveStrings.failed)
                    }
                    return nil
                }
                let run = SSHChatMoveRun(executable: acpmux.executable, environment: await SSHService.environment().merging(acpmux.childEnvironment) { $1 })
                var outcome = await run.run(chat, to: target, peers: peers, options: options)
                if case .needsConfirmation(let code, let dirty) = outcome {
                    guard interactive else { return ActionWorkFailure(SSHChatMoveStrings.message(outcome)) }
                    let running = code == "running_turn"
                    let buttons: [CmuxDialogButton] = running
                        ? [.cancel(), .init(id: "now", title: SSHChatMoveStrings.moveNow, key: "m"),
                           .init(id: "after", title: SSHChatMoveStrings.afterTurn, role: .default)]
                        : [.cancel(), .init(id: "carry", title: SSHChatMoveStrings.carryChanges, role: .default)]
                    let spec = CmuxDialogSpec(title: SSHChatMoveStrings.moveTitle,
                        lines: [dirty == true ? SSHChatMoveStrings.dirty : SSHChatMoveStrings.running],
                        buttons: buttons, identifier: "chat.move.confirm")
                    let scope: CmuxDialogScope = services.windows.active?.window.map(CmuxDialogScope.window) ?? .app
                    let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
                    guard !answer.isCancel, !answer.isDismissal else { return nil }
                    var confirmed = options
                    confirmed.afterTurn = answer.button == "after"
                    confirmed.interrupt = answer.button == "now"
                    confirmed.carryChanges = dirty == true && !confirmed.leaveDirty
                    outcome = await run.run(chat, to: target, peers: peers, options: confirmed)
                }
                guard case .moved(let moved) = outcome else { return ActionWorkFailure(SSHChatMoveStrings.message(outcome)) }
                if options.dryRun { return nil }
                guard (try? await services.sessionTransfer.openChat(moved, title: tab.titleText)) != nil else { return ActionWorkFailure(SSHChatMoveStrings.tabFailed) }
                try? await services.machines.daemon(forTab: tab).connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
                return nil
            }
        }
    }
}

extension CloudPlaceClaims {
    /// The cargo the page sent with its action (strings, as every page argument is); none when it sent none.
    init(_ invocation: ActionInvocation) {
        self.init(queued: invocation["queued"].flatMap { $0.intValue ?? $0.stringValue.flatMap(Int.init) },
                  hasDraft: invocation["hasDraft"].flatMap { $0.boolValue ?? $0.stringValue.map { $0 == "true" } })
    }
}

/// What a chat carries into a move, read from the app's own state for the reducer's `Cargo`. A person's move from the page
/// takes its `queued` and `hasDraft` from the page's claims (``CloudPlaceClaims``) when it sent them; no Swift source reads the
/// queued prompts, so Auto and Evacuate leave it out.
extension CloudPlaceFlows.Cargo {
    @MainActor static func read(tab: TabModel, session: String, services: AppServices, invocation: ActionInvocation? = nil) -> CloudPlaceFlows.Cargo {
        var cargo = Self()
        if let ref = tab.agentSession { cargo.turnRunning = AgentTurnStateStore.shared.state(for: ref) == .working }
        // Both moves run the agent move with a FrozenSync, which carries a running turn to where it lands; no turn, no carry.
        cargo.continuesTurn = cargo.turnRunning
        cargo.branch = tab.gitBranch
        let tabs = services.agentTabs
        cargo.hasDraft = tabs.unsentDrafts.hasDraft(tabs.resolve(tab.id), machine: tabs.daemonListing(tab)?.machineID)
        if let invocation {
            let claims = CloudPlaceClaims(invocation)
            cargo.queued = claims.queued ?? cargo.queued
            cargo.hasDraft = claims.hasDraft ?? cargo.hasDraft
        }
        return cargo
    }
}

/// The app's side of the chat place controls (``CloudPlaceDriver``): its chats, how it runs a move, what its ledger knows.
extension AppServices: CloudPlaceHost {
    static let placeSet: ActionID = "chatPlace.set"
    static let placeCancel: ActionID = "chatMove.cancel"
    static let placeRetry: ActionID = "chatMove.retry"
    static let placeEvacuate: ActionID = "cloudEvacuate"
    static let placeEvacuateCancel: ActionID = "cloudEvacuate.cancel"
    static let placeBringBackAll: ActionID = "cloudBringBackAll"

    func placeChats() -> [CloudPlaceChat] {
        var found: [CloudPlaceChat] = [], seen = Set<String>()
        for daemon in machines.daemons {
            for workspace in daemon.store.workspaces {
                for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                    guard let record = tab.agentSession, let session = record.session ?? agentTabs.sessions[agentTabs.tabKey(of: tab)],
                          seen.insert(session).inserted else { continue }
                    let onCloud = record.host.hasPrefix(MachineRegistry.registryHostPrefix)
                    guard daemon.isLocal && !onCloud && !record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix)
                        || onCloud && cloud.movedChats.entry(host: record.host, session: session) != nil else { continue }
                    found.append(CloudPlaceChat(id: tab.id, session: session, title: tab.titleText, onCloud: onCloud, turnRunning: CloudPlaceFlows.Cargo.read(tab: tab, session: session, services: self).turnRunning,
                                                turnStartedAtMs: AgentTurnStateStore.shared.detail(for: record)?.turnStartedAtMs.map(Double.init),
                                                moving: cloud.place.isMoving(session) || cloud.movingBack.contains(tab.id)))
                }
            }
        }
        return found
    }

    func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger, claims: CloudPlaceClaims) async {
        var arguments: [String: ActionValue] = ["trigger": .string(trigger.argument)]
        if let queued = claims.queued { arguments["queued"] = .int(queued) }
        if let hasDraft = claims.hasDraft { arguments["hasDraft"] = .bool(hasDraft) }
        switch machine {
        case .reuse(let id): arguments["machine"] = .string(id)
        case .create: arguments["newMachine"] = .bool(true)
        case nil: break
        }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.id), arguments: arguments, origin: .user)
        let registry = self.registry
        let action = toCloud ? CloudMove.action : CloudBringBack.action
        for work in registry.capturingWork({ _ = registry.perform(action, invocation: invocation) }) { _ = await work.value }
    }

    func placeCloudSessions() -> [String] { cloud.movedChats.all().filter { $0.broughtBack == nil }.map(\.session) }

    func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine]) {
        let ledger = cloud.movedChats.all()
        return (ledger.first { $0.session == session || $0.broughtBack?.session == session }?.machineID,
                machines.cloud.map { machine in
                    CloudPlaceOwnMachine(id: machine.machineID, sessions: ledger.filter { $0.machineID == machine.machineID && $0.broughtBack == nil }.map(\.session),
                                         gone: [.deleting, .destroyed].contains(machine.machine.status))
                })
    }

    func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void) {
        AgentTurnStateStore.shared.turnEndedObservers.append { session, _ in handler(session) }
    }
}
