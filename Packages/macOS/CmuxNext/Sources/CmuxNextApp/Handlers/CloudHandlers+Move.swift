import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextCloudPlace
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
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
        // Person-only (the catalog's `isPersonOnly`, which the control socket refuses): they upload this Mac's chats and folders
        // to Cloud, so an agent's run, MCP or any socket run is refused here too, with why. The person's click in the app
        // (the page's gesture-gated `action.run`, the palette) runs them; Auto's own moves run Move to Cloud and Bring Back directly.
        let place = services.cloud.placeDriver ?? CloudPlaceDriver(place: services.cloud.place, host: services)
        if services.cloud.placeDriver == nil { services.cloud.placeDriver = place; place.start() }
        for id in [AppServices.placeSet, AppServices.prioritySet, AppServices.placeRetry, AppServices.placeEvacuate, AppServices.placeCancel, AppServices.placeEvacuateCancel, AppServices.placeBringBackAll] {
            let cancels = id == AppServices.placeCancel || id == AppServices.placeEvacuateCancel
            // A cancel is never refused.
            let allowed: @MainActor () -> String? = { nil }
            bind(id, registry, reason: cancels ? allowed : reason) { invocation in
                guard !CloudMoveAsks.isAgent(invocation), !invocation.viaControlSocket else { throw ActionFailure(message: CloudMoveStrings.placeIsPersons) }
                let tab = context.daemonTab(invocation)?.0.id, named = CloudPlaceDriver.named(invocation["sessions"]?.stringValue), row = CloudPlaceDriver.row(named)
                switch id {
                case AppServices.placeSet:
                    guard let mode = invocation["mode"]?.stringValue, ["local", "cloud", "auto"].contains(mode) else { throw ActionFailure(message: "mode must be local, cloud or auto") }
                    // A move refused at once fails in the chat's flow (with Retry) and answers the page with why.
                    if let refusal = place.setMode(mode, tab: tab, session: row, claims: CloudPlaceClaims(invocation)) { throw ActionFailure(message: refusal.message) }
                case AppServices.prioritySet: if let refusal = place.setPriority(invocation["priority"]?.stringValue, tab: tab, session: row) { throw ActionFailure(message: refusal.message) }
                case AppServices.placeRetry:
                    if let refusal = place.retry(tab: tab, session: row, claims: CloudPlaceClaims(invocation)) { throw ActionFailure(message: refusal.message) }
                case AppServices.placeCancel: place.cancel(tab: tab, session: row ?? invocation["session"]?.stringValue)
                case AppServices.placeEvacuateCancel: place.cancelEvacuation()
                case AppServices.placeBringBackAll: if let refusal = place.bringBackAll(sessions: named) { throw ActionFailure(message: refusal.message) }
                default: if let refusal = place.evacuate(sessions: named) { throw ActionFailure(message: refusal.message) }
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

extension CloudPlaceRefusal {
    /// What the page and the person read.
    @MainActor var message: String {
        switch self {
        case .moving: CloudMoveStrings.inProgress
        case .bulkRunning: CloudMoveStrings.bulkRunning
        case .refused(let reason): reason
        }
    }
}

/// What a chat carries into a move: the app reads its turn, branch, draft, acpmux's queued count and the page's claims
/// (``CloudPlaceClaims``); Rust's `cloud_move_host_cargo` (cmux-cloud-start-core `moves::host::cargo`) makes the reducer's `Cargo`.
extension CloudPlaceFlows.Cargo {
    @MainActor static func read(tab: TabModel, session: String, services: AppServices, invocation: ActionInvocation? = nil) -> CloudPlaceFlows.Cargo {
        let tabs = services.agentTabs
        let claims = invocation.map { CloudPlaceClaims($0) }.map { ["queued": $0.queued as Any?, "hasDraft": $0.hasDraft as Any?].compactMapValues { $0 } }
        let facts: [String: Any?] = ["turnRunning": AppServices.turnRunning(tab.agentSession), "branch": tab.gitBranch, "claims": claims,
                                     "queued": tab.agentSession.flatMap { AgentTurnStateStore.shared.detail(for: $0)?.queued },
                                     "hasDraft": tabs.unsentDrafts.hasDraft(tabs.resolve(tab.id), machine: tabs.daemonListing(tab)?.machineID)]
        let reply = AppServices.placeRules("cargo", facts.compactMapValues { $0 })
        var cargo = Self(); (cargo.queued, cargo.branch) = (reply["queued"] as? Int, reply["branch"] as? String)
        (cargo.turnRunning, cargo.continuesTurn, cargo.hasDraft) = (reply["turnRunning"] as? Bool ?? false, reply["continuesTurn"] as? Bool ?? false, reply["hasDraft"] as? Bool ?? false)
        return cargo
    }
}

/// The app's side of the chat place controls (``CloudPlaceDriver``): its chats, how it runs a move, what its ledger knows.
extension AppServices: CloudPlaceHost {
    static let placeSet: ActionID = "chatPlace.set"
    static let prioritySet: ActionID = "chatPriority.set"
    static let placeCancel: ActionID = "chatMove.cancel"
    static let placeRetry: ActionID = "chatMove.retry"
    static let placeEvacuate: ActionID = "cloudEvacuate"
    static let placeEvacuateCancel: ActionID = "cloudEvacuate.cancel"
    static let placeBringBackAll: ActionID = "cloudBringBackAll"

    /// The app's agent tabs, in window order, as `cloud_move_host_chats` reads them; Rust picks the eligible ones, once per session.
    func placeChats() -> [CloudPlaceChat] {
        var tabs: [[String: Any]] = []
        for daemon in machines.daemons {
            for tab in daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) {
                guard let record = tab.agentSession else { continue }
                let detail = AgentTurnStateStore.shared.detail(for: record), session = record.session ?? agentTabs.sessions[agentTabs.tabKey(of: tab)]
                let row: [String: Any?] = ["id": tab.id, "host": record.host, "session": session, "local": daemon.isLocal, "title": tab.titleText,
                                           "turnRunning": Self.turnRunning(record), "turnStartedAtMs": detail?.turnStartedAtMs.map(Double.init),
                                           "moving": session.map { cloud.place.isMoving($0) } == true || cloud.movingBack.contains(tab.id), "queued": detail?.queued ?? 0]
                tabs.append(row.compactMapValues { $0 })
            }
        }
        let chats = Self.placeRules("chats", ["moved": placeLedger, "tabs": tabs])["chats"] as? [[String: Any]] ?? []
        return chats.map {
            CloudPlaceChat(id: $0["id"] as? String ?? "", session: $0["session"] as? String ?? "", title: $0["title"] as? String ?? "",
                           onCloud: $0["onCloud"] as? Bool ?? false, turnRunning: $0["turnRunning"] as? Bool ?? false,
                           turnStartedAtMs: ($0["turnStartedAtMs"] as? NSNumber)?.doubleValue, moving: $0["moving"] as? Bool ?? false, queued: $0["queued"] as? Int ?? 0)
        }
    }

    /// Whether the place actions can move this chat (`cloud_move_host_eligible`). The header's `place` and ``placeChats()``
    /// both ask this, so the composer and Runs On offer a control only where a pick does something.
    func placeEligible(_ record: AgentSessionRef, session: String, on daemon: DaemonService) -> Bool {
        Self.placeRules("eligible", ["moved": placeLedger, "host": record.host, "session": session, "local": daemon.isLocal])["eligible"] as? Bool ?? false
    }

    func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger, claims: CloudPlaceClaims) -> CloudPlaceRun {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.id), arguments: claims.arguments(trigger: trigger, machine: machine), origin: .user)
        let registry = self.registry
        let action = toCloud ? CloudMove.action : CloudBringBack.action
        var ran = false, work: [ActionWork] = []
        // The move's own checks refuse before it starts (no chat there, no first message, no folder): that refusal is the run's answer.
        let refusal = registry.reportingRefusal { work = registry.capturingWork { ran = registry.perform(action, invocation: invocation) } }
        if work.isEmpty {
            let facts: [String: Any?] = ["refusal": refusal, "ran": ran, "unavailable": ran ? nil : registry.unavailableReason(for: action), "failed": CloudMoveStrings.moveFailed("")]
            if let reason = Self.placeRules("run_refusal", facts.compactMapValues { $0 })["refusal"] as? String { return .refused(reason) }
        }
        let started = work
        return .started { for work in started { _ = await work.value } }
    }

    func placeCloudSessions() -> [String] { Self.placeRules("sessions", ["moved": placeLedger])["sessions"] as? [String] ?? [] }

    func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine]) {
        let request: [String: Any?] = ["moved": placeLedger, "session": session, "lastMachine": cloud.place.lastMachine(of: session),
                                       "machines": machines.cloud.map { ["id": $0.machineID, "status": $0.machine.status.rawValue] }]
        let reply = Self.placeRules("own_facts", request.compactMapValues { $0 })
        return (reply["before"] as? String, (reply["machines"] as? [[String: Any]] ?? []).map {
            CloudPlaceOwnMachine(id: $0["id"] as? String ?? "", sessions: $0["sessions"] as? [String] ?? [], gone: $0["gone"] as? Bool ?? false)
        })
    }

    func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void) {
        AgentTurnStateStore.shared.turnEndedObservers.append { session, _ in handler(session) }
    }

    /// The account, team and Cloud a new machine is made under now (as an Always grant is scoped, ``CloudMoveAsks``).
    func placeIdentity() -> CloudPlaceIdentity? {
        let auth = cloud.auth
        guard auth.isSignedIn else { return nil }
        return CloudPlaceIdentity(user: auth.user?.id, team: auth.teamID, cloud: auth.configuration.apiBaseURL.absoluteString)
    }

    func placeIdentityChangedReason() -> String { CloudMoveStrings.identityChanged }

    /// One `cloud_move_host_*` op's answer (cmux-cloud-start-core `moves::host`); empty when the FFI does not answer.
    static func placeRules(_ operation: String, _ request: [String: Any]) -> [String: Any] {
        CloudHandlerRules().ask("cloud_move_host_" + operation, request) ?? [:]
    }

    /// The moved-chat ledger's entries, as the host ops read them.
    var placeLedger: Any { CloudHandlerRules.any(cloud.movedChats.all()) }

    /// The agent's turn state is `working`.
    static func turnRunning(_ record: AgentSessionRef?) -> Bool { record.map { AgentTurnStateStore.shared.state(for: $0) == .working } ?? false }
}
