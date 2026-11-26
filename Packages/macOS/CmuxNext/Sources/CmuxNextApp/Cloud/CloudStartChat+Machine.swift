import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// Which Cloud machine a `cloud.startChat` send runs on is cmux-tui's call (`cmux link start-chat
/// plan`, `link/start_chat_cli/pick.rs`): a new machine for chats, or a ready owner machine when
/// readiness selected that machine's Claude login. A retry of the same send stays on
/// the machine its first try took. The App lists its machines for it, makes the machine it asks
/// for, and connects (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT").
/// Each send is kept under the account it began in (``CloudStartCore/accountText(_:)``), and takes a machine only
/// of the list the server answered for that account (``checkAccount(_:now:listCurrent:)``).
extension CloudStartChat {
    /// The plan's request: the send's key, account and Mac workspace, who is signed in (`user`: the platform `user_…` id a machine's `created_by` names, not the Stack id,
    /// or no machine is the person's to reuse), the account's listed machines, the store's others (`stored`), and the chat's folder, environment and token flag (`access`).
    static func planRequest(key: String, account: [String?], workspace: String?, user: String?, machines: [CloudMachineSession],
                            local: String? = nil, stored: [String], environment: String? = nil, access: Bool = false, reservationKey: String? = nil, machine: String? = nil,
                            readiness: (choice: CloudSetup.Choice, machines: Set<String>), platform: String? = nil, ensureProject: Bool? = nil, size: CloudChatSize? = nil, bytes: Int64? = nil, planMax: CloudChatSize? = nil) -> String {
        let listed: [[String: Any]] = machines.map { session in
            let connected = session.daemon.connection != nil
            let chats = connected ? session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .filter { $0.agentSession != nil }.count : nil
            var entry = session.machine.startChatPlanEntry(connected: connected, chats: chats)
            entry["claude_ready"] = readiness.machines.contains(session.machineID)
            return entry
        }
        var request: [String: Any] = ["key": key, "account": CloudStartCore().accountText(account), "loaded": true, "machines": listed,
                                      "stored": stored, "claude_machine_login": readiness.choice == .claudeMachineLogin, "credential_on_stdin": access, "reservation_key": reservationKey, "platform": platform, "ensure_project": ensureProject, "size": size?.requested, "bytes": bytes, "plan_max": planMax?.rawValue]
        for (name, value) in [("user", user), ("workspace", workspace), ("local", local), ("environment", environment), ("machine", machine)] { request[name] = value }
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Where this App kept its sends before cmux-tui did. Handed over once, so a send in flight keeps its machine and copy.
    static let keptSendsKey = "cmux.cloud.startChatDestinations"

    /// Hands the sends this App kept itself to cmux-tui, then forgets them. A failed hand-over refuses the send and keeps them.
    func importKeptSends(_ cli: CloudMoveCLI) async throws {
        guard let defaults = services.cloud.move.ledger, let data = defaults.data(forKey: Self.keptSendsKey) else { return }
        _ = try Self.checked(await cli.startChatImport(entries: String(decoding: data, as: UTF8.self)))
        defaults.removeObject(forKey: Self.keptSendsKey)
    }

    /// Refuses a send whose account changed since it began (`asked`), or whose machine list is not
    /// the server's answer for the account signed in now (`listCurrent`): after a team switch the
    /// previous team's machines stay in the store until that list lands, and the chat's folder must
    /// never be copied to one of them.
    static func checkAccount(_ asked: [String?], now: [String?], listCurrent: Bool) throws { // the rule: cmux-cloud-start-core `start`
        guard let check = CloudStartCore().checkAccount(asked, now: now, listCurrent: listCurrent) else { return }
        throw CloudMove.Failure(message: check == .accountChanged ? CloudMoveStrings.startChatAccountChanged : CloudMoveStrings.startChatListUnread)
    }

    /// Connects the send's pinned machine or creates and pins one sized for the chat.
    func machine(for start: AgentPaneCloudStart, from origin: Origin, cli: CloudMoveCLI, invocation: ActionInvocation,
                 direct: Bool = true, pick: () async -> CloudWorkPick?) async throws -> (CloudMachineSession, CloudMoveCLI.StartChatPlan, AgentSessionAttachClient.ClaudeAuth?) {
        let (machines, cloud, account, workspace, connection) = (services.machines, services.cloud, origin.account, origin.workspace, origin.connection)
        await CloudWait.firstList(loaded: { cloud.hasLoadedCurrentMachines }, signedIn: { cloud.isSignedIn }) { _ = await cloud.refresh() } // Rust's `list_wait`; the card shows the machine step meanwhile
        try await importKeptSends(cli)
        try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
        let listed = cloud.listedMachineIDs
        let ensureProject = CloudStartCore().ensuresProject(account: account, platform: cloud.configuration.artifactsAPIBaseURL(), production: cloud.auth.configuration.isProductionAuth)
        let reserved = start.machine == nil && start.environment == nil && start.reservationKey != nil
        async let installRead = { @MainActor in reserved ? try await cloud.installIdentity.installToken() : nil }()
        async let accessRead = { @MainActor in ensureProject || reserved ? try await cloud.auth.tokens().access : nil }()
        let access = try? await accessRead, install = try await installRead
        let request = Self.planRequest(key: start.key, account: account, workspace: workspace, user: cloud.auth.platformUserID,
                                       machines: machines.cloud.filter { listed.contains($0.machineID) }, local: start.home ? nil : start.uploadRoot ?? start.cwd,
                                       stored: machines.cloud.map(\.machine).keptForPin(listed: listed), environment: start.environment, access: access != nil,
                                       reservationKey: reserved ? start.reservationKey : nil, machine: start.machine, readiness: origin.readiness, platform: cloud.configuration.artifactsAPIBaseURL()?.absoluteString, ensureProject: ensureProject, size: start.size, bytes: start.folderBytes, planMax: start.planMax)
        try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
        var plan = try Self.checked(await cli.startChatPlan(request: request, access: access, install: install))
        if let id = start.machine, plan.machine != id || !listed.contains(id) { throw CloudMove.Failure(message: CloudMoveStrings.noSuchMachine(id)) }
        timeline?.mark("machine.plan") // the list, the tokens and the plan (a reservation's claim)
        var invocation = invocation
        if let id = plan.machine, !listed.contains(id) {
            await cloud.refresh() // List a platform-reserved or project machine before attaching.
            // A remembered machine that is gone (deleted, other backend) is dropped: the send makes a new one (DEV 9fa9b1c3).
            if machines.session(id) == nil {
                cloud.logger.info("cloud start chat: the planned machine \(id, privacy: .public) is gone; making a new one")
                plan.machine = nil; plan.ensuredEnvironment = nil
                plan.createSent = false
            }
        }
        if let id = plan.machine { invocation.arguments["machine"] = .string(id) } else {
            if !plan.createSent {
                _ = try Self.checked(await cli.startChatCreateBegin(key: start.key, account: CloudStartCore().accountText(account), name: plan.newName ?? "cloud-chats", createKey: plan.createKey))
            }
            let request = CloudMachineRequest(startChatKey: plan.createKey, sizedFor: await pick(), team: plan.createTeam ?? (account.last ?? nil), size: start.size, diskMb: start.grownDiskMb, planMax: start.planMax, bytes: start.folderBytes, plan: plan, environment: start.environment)
            try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
            // The account is checked again once the server answered, before the machine joins the list. The Send is the person's own gesture
            // (the pane took it, `AgentPaneHandOff`), so a fresh key goes as them, with no approval to hold and answer; its route is kept with the key.
            let created: CloudMachineSession
            do {
                created = try await cloud.createMachine(name: plan.newName, startedByPerson: invocation.origin == .user, ownCreate: plan.ownCreate(personsOwnRun: invocation.isPersonsOwnRun && ActionRunScope.isPersonsAction(), relayOnly: !direct),
                                                            request: request, onAppServerSent: { team, route in
                    _ = try Self.checked(await cli.startChatCreateSent(key: start.key, account: CloudStartCore().accountText(account), team: team, createKey: plan.createKey, route: plan.recorded(route)))
                }) {
                    try Self.checkAccount(account, now: cloud.account, listCurrent: true)
                }
            } catch let failure as CloudAppOpFailure where !Task.isCancelled && CloudStartCore().isDefinitiveRefusal(failure) {
                _ = try Self.checked(await cli.startChatCreateRefused(key: start.key, account: CloudStartCore().accountText(account), createKey: plan.createKey))
                throw failure
            } catch is CloudPersonCreate.Unavailable where direct && !plan.createSent && !Task.isCancelled { // the direct route refused before the op ran: the ledger gives the start a new key, which the relay takes
                _ = try Self.checked(await cli.startChatCreateRefused(key: start.key, account: CloudStartCore().accountText(account), createKey: plan.createKey))
                return try await machine(for: start, from: origin, cli: cli, invocation: invocation, direct: false, pick: pick)
            }
            invocation.arguments["machine"] = .string(created.machineID)
        }
        let id = invocation.arguments["machine"]?.stringValue, text = CloudStartCore().accountText(account)
        return try await cloud.startGate.entering(id ?? "") { try await cli.releasing(made: plan.madeForStart ? id : nil, key: start.key, account: text, sameAccount: { account == cloud.account }, delete: { try await cloud.deleteMachine($0) }) { // held from before its connect, so its handshake's automatic update never restarts it under the start (cmux#55519); a failed pin, attach or route deletes a machine made for this start
            // Beside the link's connect (nothing on the machine, cmux#45953): the pin, this Mac's own record, and a new machine's route report (no spare read it ahead), whose exec (1.9-2.5 s) ran after the 8-11 s connect until 2026-11-25; one that does not say the chat starts is read again after (leo: "when you press enter, the stuff should just start playing").
            let pinMachine = plan.machine == nil ? id : nil, key = start.key
            async let pinned: Void = { @MainActor in if let pinMachine { _ = try Self.checked(await cli.startChatPin(key: key, account: text, machine: pinMachine, workspace: workspace)) } }()
            async let routeAhead: String? = { @MainActor in if let pinMachine { await CloudMachineRoute(api: cloud.machineAPI, machineID: pinMachine).report() } else { nil } }()
            let shown = machines.session(id ?? ""); shown?.waking = asker?.waking; defer { shown?.waking = nil } // the card's "Waking machine" while it settles
            let session: CloudMachineSession
            do { session = try await CloudMove(services: services).machine(invocation, pick: pick) } catch { _ = try? await pinned; _ = await routeAhead; throw error }
            try await pinned
            timeline?.mark("machine.connect")
            let machineID = session.machineID, readAhead = session.machineID == pinMachine ? await routeAhead : nil
            try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
            guard CloudStartCore().matchesEnvironment(start.environment, machine: session.machine, ensured: plan.ensuredEnvironment) else { throw CloudStartSessionStrings.environmentMismatch }
            session.machine = cloud.setup.machineEnvironment(session.machine, ensured: plan.ensuredEnvironment, account: account, defaults: cloud.move.ledger)
            let launchConnection = await cloud.setup.launchConnection(connection)
            let endpoint = launchConnection?.endpointCredentials == true
            let subscription = launchConnection?.subscriptionCredentials == true
            let capability = AgentSessionAttachClient.credentialsCapability(harness: start.harness, nativeKey: endpoint,
                                                                                      subscription: subscription)
            if endpoint {
                try await CloudOutdatedMachine.requireCapability(
                    holds: { services.agentTabs.holdsTabs(session.daemon) && session.daemon.supports(capability) },
                    lacks: { !session.daemon.supports(capability) },
                    update: { await CloudMachineUpdates.updateNow(machineID, services: services) },
                    missing: CloudMove.Failure(message: CloudMachineRoute.tooOld, retry: .move(machineID: machineID))
                )
            }
            try Self.requireEndpointHarness(launchConnection?.launchHarness, on: session, subscription: subscription)
            let (choice, refusal): (CloudSetup.Choice, CloudSetup.Refusal?) = origin.readiness.choice.claudeAuth == .team
                ? (origin.readiness.choice, nil)
                : await cloud.setup.launchReadiness(for: start.onMachine(machineID), checkMachineLogin: connection == nil)
            let machineLogin = connection == nil && choice == .claudeMachineLogin
            if connection == nil, refusal?.family == "claude" { throw CloudMachineRoute.NeedsClaudeLogin(machine: machineID) }
            if start.machine != nil || machineLogin {
                let owned = await CloudMachineLinks(appLink: session.appLink).ownerLink() != nil
                if owned && machineLogin { return (session, plan, .own) }
                if !owned, start.machine != nil { throw CloudMove.Failure(message: CloudMoveStrings.noSuchMachine(machineID)) }
            }
            try await CloudMachineRoute(api: cloud.machineAPI, machineID: machineID, start: { @MainActor [invocation] in try await CloudWait.startStopped(status: { session.machine.shownStatus }, within: CloudStartSession.connectWait, read: { await session.refresher?($0) }) { do { try await session.resumer?(machineID, CloudHandlers.connectOrigin(for: invocation)) } catch where !CloudMachineRoute.keepsItsError(error) && CloudMachineCreation.proRefusal(error) == nil { throw CloudMove.Failure(message: CloudMoveStrings.moveFailed(CloudStrings.errorText(error)), retry: .move(machineID: machineID)) } }; _ = try await CloudMove.connected(session, invocation) }).prepare(serves: {
                services.agentTabs.holdsTabs(session.daemon) && (connection == nil || session.daemon.supports(capability))
            }, carriesConnection: connection != nil,
                family: endpoint ? (start.harness ?? "claude") : CloudSetup.family(of: start.harness),
                ahead: (cloud.spareReadiness.takeRouteReport(machineID, scope: cloud.account, instance: AcpmuxRemotePersonKeys.shared.instance(machine: machineID)) ?? readAhead).flatMap { session.machine.status == .running && session.machine.pendingChange == nil ? $0 : nil },
                requiresCredentialCapability: endpoint) { @MainActor [services] in _ = await CloudMachineUpdates.updateNow(machineID, services: services) } // checked first: updated only when it lacks what a start uses
            timeline?.mark("machine.route")
            return (session, plan, choice.claudeAuth == .team && connection == nil ? .team : nil)
        } }
    }

    /// A current daemon can report that an endpoint's runner is missing from this machine.
    static func requireEndpointHarness(_ harness: String?, on session: CloudMachineSession, subscription: Bool) throws {
        guard let harness, let installed = session.credentialHarnesses(subscription: subscription), !installed.contains(harness) else { return }
        let refusal = AgentRemoteStartRefusal(code: AgentRemoteStartRefusal.harnessMissingCode, machine: session.machine.title)
        throw CloudMove.Failure(message: refusal.userMessage)
    }

    static func checked<T>(_ answer: (CloudMoveCLI.Answer, T)) throws -> T { try CloudMoveStrings.checked(answer) }
}
