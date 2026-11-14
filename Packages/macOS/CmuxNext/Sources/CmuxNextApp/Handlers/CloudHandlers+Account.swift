import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

// Creation (new machine, new cloud workspace), sign in/out, team picker,
// and diagnostics.
extension CloudHandlers {
    static func bindCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bindMachineCreation(into: registry, context: context, reason: reason)
        bind("newCloudWorkspace", registry, reason: { reason() ?? (cloud.isSignedIn ? nil : CloudStrings.signInFirst) }) { invocation in
            let target = try workspaceMachine(invocation, context)
            if let target { try requireAttachableState(target) }
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            let route = CloudHandlerRules().ask("cloud_handler_new_workspace", [
                "hasTarget": target != nil, "connected": target?.daemon.connection != nil,
                "byUser": origin(of: invocation) == .user, "hasWindow": window != nil,
            ])?["route"] as? String
            guard let session = target, route == "workspace" else {
                if route == "setup" {
                    beginWorkspaceSetup(context, window: window, askedBy: invocation.callerAgentSession)
                    return
                }
                // A new machine, or one still on its way: show its progress
                // now. An ended app link connects again on this gesture, and
                // a paused machine resumes (idle auto-pause).
                target?.attach(origin: connectOrigin(for: invocation))
                let creation = creationFlow(context, startedByPerson: invocation.origin == .user, capCard: invocation.isPersonsOwnRun, askedBy: invocation.callerAgentSession,
                                            reveals: invocation.allowsViewChange).start(in: window, existing: target)
                guard let target else {
                    // A CLI or agent hears the new machine's id and target once the server has it
                    // (workspace_id too when it is already open), else pending: true; a refusal
                    // (a plan the create needs) reaches it as a failure, never a card.
                    reportCreatedMachine(creation, context)
                    return
                }
                // A CLI or agent hears that the workspace comes later: its machine is connecting.
                result("new cloud workspace", context) {
                    machineFields(target.machineID).merging(["pending": .bool(true), "status": .string("connecting")]) { field, _ in field }
                }
                return
            }
            result("new cloud workspace", context) {
                // Made in the window it was asked from, like a local New Workspace; a CLI or agent
                // run without focus leaves every window's view as it is.
                // Placed as any new workspace (`workspaces.newPlacement`), in no group of its machine's (Leo 2026-11-06).
                let id = await context.services.windows.createWorkspace(on: session.daemon, into: window?.id)
                guard let id else { throw ActionFailure(message: CloudStrings.notConnected) }
                if invocation.allowsViewChange { show(id, context) }
                return machineFields(session.machineID, ["workspace_id": .string(id)])
            }
        }
    }

    /// The asking chat's folder: its tab's cwd, else the folder its local session reports (a chat
    /// tab may have no cwd cached yet), as Move to Cloud reads it.
    static func chatFolder(_ chat: TabModel?, _ services: AppServices) async -> String? {
        guard let chat else { return nil }
        if let cwd = chat.cwd, cwd.hasPrefix("/") { return cwd }
        let tabs = services.agentTabs
        guard let session = tabs.sessions[tabs.tabKey(of: chat)] ?? chat.agentSession?.session else { return nil }
        let host = tabs.localSessionHost ?? tabs.host
        guard let folder = try? await host.sessionFolder(sessionId: session), folder.isLocal, folder.cwd.hasPrefix("/") else { return nil }
        return folder.cwd
    }

    static func beginWorkspaceSetup(_ context: AppActionContext, window: WindowState?, askedBy: String?, chat: TabModel? = nil, environment: String? = nil) {
        runTracked("new Cloud workspace", context) {
            let cloud = context.services.cloud, services = context.services
            let userID = cloud.auth.user?.id, teamID = cloud.auth.teamID
            // Release: read the remote switch now, so the offer below reflects it (DEV and NIGHTLY skip it).
            if !DevTools.isEnabled { await cloud.readHarnessLoginCopySwitch() }
            let availability = CloudWorkspaceSetupWizard.CredentialAvailability.resolve(
                teamID: cloud.auth.teamID, supportsFileRoute: AgentTabStore.cloudCredentialTransferIsAvailable(isSignedIn: true, passesLogin: true),
                passesLogin: CloudCredentialTransfer.passesHarnessLogin(isDogfoodBuild: DevTools.isEnabled, defaults: .standard, remoteSwitch: cloud.harnessLoginCopySwitch.current))
            let present: (CmuxDialogSpec) async -> CmuxDialogAnswer = { spec in
                let scope: CmuxDialogScope = services.windows.active?.window.map(CmuxDialogScope.window) ?? .app
                return await CmuxDialogCenter.shared.present(spec, in: scope)
            }
            let wizard = CloudWorkspaceSetupWizard(), pick = await CloudChatPick(services: services).read(folder: await chatFolder(chat, services), tab: chat)
            // Environments live in the cmux-next backend's CloudDO.
            let environments = (try? await cloud.appServerEnvironmentOptions()) ?? []
            guard let plan = try await wizard.choosePlan(availability: availability,
                scopeIsCurrent: { cloud.auth.user?.id == userID && cloud.auth.teamID == teamID },
                // The app server's create takes no repository and no size for now.
                supportsRepository: false, suggested: pick?.repo,
                environments: environments, supportsEnvironments: true, selectedEnvironment: environment,
                sizes: [], autosized: pick?.autosize != nil && pick?.repo != nil, present: present) else { return }
            var request = CloudChatPick.request(plan, sizedFor: pick)
            if let new = plan.newEnvironment {
                // Saved first, then booted: the first machine starts cold and runs the setup itself.
                guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                request.environment = try await cloud.appServerSaveEnvironment(new)
            }
            request.script = try await request.loadScript(work: services.work)
            try Task.checkCancellation()
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
            let creation = creationFlow(context, startedByPerson: true, askedBy: askedBy, proceed: { creation in
                try checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                       currentUserID: cloud.auth.user?.id, currentTeamID: cloud.auth.teamID)
            }).start(in: window, existing: nil, request: request)
            // Failed attempts remain listed for Retry. Only readiness, explicit dismissal,
            // teardown, cancellation, or an account change ends this observation.
            for await (readiness, currentUser, currentTeam) in ObservationStream({
                (workspaceSetupReadiness(creation, in: cloud.creations), cloud.auth.user?.id, cloud.auth.teamID)
            }) {
                do {
                    try checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                           currentUserID: currentUser, currentTeamID: currentTeam)
                } catch is CancellationError { return }
                guard readiness != .ended else { return }
                if readiness == .ready { break }
            }
            guard !creation.isTornDown, let session = creation.session else { return }
            try Task.checkCancellation()
            if plan.repository != nil {
                // The completion task outlives the progress row. Account changes wake this observer;
                // the bootstrap's bounded completion result ends it on success or failure.
                for await (progress, currentUser, currentTeam) in ObservationStream({
                    (workspaceSetupCompletion(creation), cloud.auth.user?.id, cloud.auth.teamID)
                }) {
                    do {
                        try checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                               currentUserID: currentUser, currentTeamID: currentTeam)
                    } catch is CancellationError { return }
                    guard !progress.ended else { return }
                    guard let completion = progress.completion else { continue }
                    try Task.checkCancellation()
                    guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                    try await wizard.finishBootstrap(completion) { path in
                        let filing = ActionRunScope.carrying(ActionRunScope(origin: .user, allowsViewChange: false)) {
                            // task-owner: this awaited filing; cancellation below ends its task
                            Task { await services.windows.createWorkspace(cwd: path, on: session.daemon, into: window?.id) }
                        }
                        let id = await withTaskCancellationHandler { await filing.value } onCancel: { filing.cancel() }
                        guard let id else {
                            throw ActionFailure(message: CloudStrings.notConnected)
                        }
                        try Task.checkCancellation()
                        guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                        if CloudWorkspaceSetupWizard.shouldRevealProject(originalWorkspace: creation.workspaceID,
                            currentWorkspace: window?.workspaceID, windowIsActive: services.windows.active?.state.id == window?.id) {
                            show(id, context)
                        }
                    }
                    break
                }
            }
            try Task.checkCancellation()
            guard !creation.isTornDown, availability == .available, let userID,
                  cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
            try await wizard.offerCredentialSetup(machine: session.machine.title,
                account: cloud.auth.activeTeam.team?.displayName ?? CloudWorkspaceSetupWizard.personalAccountTitle, present: present) { provider in
                try Task.checkCancellation()
                guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else {
                    throw CancellationError()
                }
                if provider == .codex {
                    // The Release consent covers the Claude login only; the Codex broker stays DEV and NIGHTLY.
                    guard DevTools.isEnabled else { return }
                    guard let windowID = window?.id, let originalWindow = services.windows.controller(for: windowID)?.window else {
                        throw CancellationError()
                    }
                    try await cloud.codexBroker.run(machineID: session.machineID,
                        scope: .init(userID: userID, teamID: teamID), confirmed: true,
                        askLocalSignIn: { await CloudStartChat.askCodexSignIn(services, mayAsk: true, in: .window(originalWindow)) },
                        presentDeviceCode: { prompt in
                            await CloudPresenter.presentCodexDeviceCode(prompt, in: .window(originalWindow))
                        })
                    return
                }
                guard await CloudStartChat.loginCopyGate(services).copyAllowed() else { return } // the transfer checks it again last
                let transfer = CloudCredentialTransfer(provider: .claude,
                    machineID: session.machineID, teamID: teamID, userID: userID,
                    otherTeams: cloud.auth.loginScopes, openTerminal: { [weak services] line in
                        await services?.openLocalProviderLogin(line) ?? false
                    })
                try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID },
                                       currentUserID: { cloud.auth.user?.id }, confirmed: true,
                                       callerOwnsVM: { [machineID = session.machineID] in try await cloud.callerOwnsVM(machineID) },
                                       stillAllowed: CloudStartChat.loginCopyGate(services).stillAllowed)
            }
        }
    }

    /// A retryable failure is still waiting. Mirroring removes the progress row normally;
    /// explicit teardown ends the wizard even when it already opened a workspace.
    static func workspaceSetupReadiness(_ creation: CloudMachineCreation, in creations: CloudCreations) -> CloudWorkspaceSetupWizard.Readiness {
        let readiness = CloudHandlerRules().ask("cloud_handler_setup_readiness", [
            "tornDown": creation.isTornDown, "hasWorkspace": creation.workspaceID != nil, "listed": creations.creation(creation.id) != nil,
        ])?["readiness"] as? String
        switch readiness {
        case "ready": return .ready
        case "waiting": return .waiting
        default: return .ended
        }
    }

    /// Normal row removal keeps the clone wait alive; teardown wakes it without a result.
    static func workspaceSetupCompletion(_ creation: CloudMachineCreation) -> (completion: CloudMachineBootstrap.Completion?, ended: Bool) {
        (creation.bootstrapCompletion, creation.isTornDown)
    }

    /// The machine New Cloud Workspace opens on, nil for a new one of the workspace's own
    /// (``CloudNewWorkspaceMachine``; design/cloud.md rule 1). A named `--target machine:<id>`
    /// that is not there is refused, never answered with a new machine. The person's own
    /// gesture opens on the machine their window shows; a CLI, MCP or agent run with no
    /// target, or a person with no Cloud machine in view, gets a new machine, never the only
    /// or first listed one (a teammate's, or a fleet lane VM).
    static func workspaceMachine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> CloudMachineSession? {
        let machines = context.services.machines
        let focused = context.services.windows.active?.state.machineID
        let named = invocation.target?.kind == .machine ? invocation.target?.id : nil
        switch CloudNewWorkspaceMachine.pick(named: named, byPerson: origin(of: invocation) == .user && invocation.isPersonsOwnRun,
                                             focused: focused.flatMap { machines.session($0) == nil ? nil : $0 }) {
        case .named: return try machine(invocation, context)
        case .focused(let id): return machines.session(id)
        case .new: return nil
        }
    }

    // MARK: cloud new-machine with options

    /// The invocation's `name`, `size`, `persistent`, `bootstrap`, `bootstrapScript`, `machineConfig` and `repo`,
    /// checked by the rules. Reads no file: the script is loaded off the main thread before the create.
    static func newMachineRequest(_ invocation: ActionInvocation) throws -> CloudMachineRequest {
        let checked = try CloudHandlerRules().arg("newMachine", invocation, extra: ["home": NSHomeDirectory()]) as? [String: Any] ?? [:]
        var request = CloudMachineRequest(name: checked["name"] as? String, size: checked["size"] as? String, memoryMb: checked["memoryMb"] as? Int,
                                          persistent: checked["persistent"] as? Bool ?? false, bootstrapPath: checked["bootstrapPath"] as? String,
                                          bootstrapKind: checked["bootstrapKind"] as? String == "lane" ? .lane : .plain)
        request.machineConfigPath = checked["machineConfigPath"] as? String
        // A bare `--environment` (no value) arrives as `true`: refused, never a machine without it.
        if let environment = invocation["environment"] {
            guard let word = environment.stringValue else { throw CloudWorkspaceSetupWizard.EnvironmentOption.Unknown() }
            request.environment = try CloudWorkspaceSetupWizard.EnvironmentOption.word(word) // an env_ id, or a name createRequested reads
        }
        // The rules parsed `--repo` (a login or token in it is refused, never echoed).
        if let repo = checked["repo"] as? [String: Any], let owner = repo["owner"] as? String, let name = repo["name"] as? String,
           let host = repo["host"] as? String {
            request.repo = CloudMachineRepo(owner: owner, name: name, ref: repo["ref"] as? String, host: host)
        }
        return request
    }

    /// The request's facts for the rules (``CloudHandlerRules``).
    static func requestFacts(_ request: CloudMachineRequest) -> [String: Any] {
        ["name": request.name as Any, "size": request.size as Any, "memoryMb": request.memoryMb as Any, "persistent": request.persistent,
         "bootstrapPath": request.bootstrapPath as Any, "bootstrapKind": request.bootstrapKind == .lane ? "lane" : "plain",
         "machineConfigPath": request.machineConfigPath as Any,
         "repo": request.repo.map { ["owner": $0.owner, "name": $0.name, "ref": $0.ref as Any, "host": $0.host,
                                     "spec": $0.spec, "url": $0.url, "directory": $0.directory].compacted } as Any].compacted
    }

    static func outcomeFacts(status: String, reason: String?, statusFile: String, log: String) -> [String: Any] {
        ["status": status, "reason": reason as Any, "statusFile": statusFile, "log": log].compacted
    }

    /// The `machine_config` answer of a start (``CloudMachineConfig``): its status and how to read it.
    static func machineConfigAnswer(_ outcome: CloudMachineBootstrap.Outcome, machineID: String) -> ActionResultValue {
        let facts = outcomeFacts(status: outcome.status, reason: outcome.reason, statusFile: CloudMachineConfig.statusPath, log: CloudMachineConfig.logPath)
        return CloudHandlerRules().ask("cloud_handler_machine_config", ["outcome": facts, "machineId": machineID])?["answer"].map(CloudHandlerRules.result) ?? .null
    }

    /// Loads the bootstrap script before anything is created (an unreadable script costs no
    /// machine), starts the creation (its progress shows like any New Cloud Machine), then runs
    /// the bootstrap on the machine the server returned. Answers the machine's facts, the
    /// request's, `bootstrap` and `enrollment`. After ``createdMachineWait`` it answers
    /// `pending`, and the create and the bootstrap go on (`cloud list-machines` shows the
    /// machine; its bootstrap status file says how far it got).
    static func createRequested(_ request: CloudMachineRequest, flow: CloudCreationFlow, window: WindowState?, _ context: AppActionContext) {
        let cloud = context.services.cloud, creations = cloud.creations, work = context.services.work
        result("new Cloud machine", context, pendingAfter: createdMachineWait, pending: newMachineFields(request, nil).merging(["status": .string("creating")]) { _, new in new }) {
            var request = request
            do { request.script = try await request.loadScript(work: work) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                throw ActionFailure(message: CloudStrings.bootstrapScriptUnreadable(unreadable.path))
            }
            do { request.machineConfig = try await request.loadMachineConfig(work: work) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                throw ActionFailure(message: CloudStrings.machineConfigUnreadable(unreadable.path))
            }
            if let wanted = request.environment { request.environment = try await CloudWorkspaceSetupWizard.EnvironmentOption.id(for: wanted, loading: { try await cloud.appServerEnvironmentOptions() }) }
            try CloudWorkspaceSetupWizard.EnvironmentOption.NameRefused.check(request.name, await request.namedCreate(listCurrent: { cloud.hasCurrentList(within: CloudStartSession.listFresh) }, refresh: { await cloud.refresh() }, machines: { context.services.machines.cloud.map(\.machine.title) }, creating: { name in cloud.creations.all.filter { $0.session == nil }.compactMap(\.request.name) + (cloud.startSessionRuns.isCreating(name, account: cloud.account) ? [name] : []) }))
            let creation = flow.start(in: window, existing: nil, request: request)
            if case .failed(let reason)? = await settledCreation(creation, in: creations) { throw ActionFailure(message: "new Cloud machine: \(reason)") }
            guard let session = creation.session else { throw ActionFailure(message: CloudStrings.createDeclined) }
            var made: [String: Any] = ["machine": machineFacts(session), "workspaceId": creation.workspaceID as Any]
            if let script = request.script, let outcome = creation.bootstrap {
                made["scriptKind"] = script.kind.rawValue
                made["bootstrap"] = outcomeFacts(status: outcome.status, reason: outcome.reason, statusFile: CloudMachineBootstrap.statusPath, log: CloudMachineBootstrap.logPath)
            }
            if request.machineConfig != nil, let outcome = creation.machineConfig {
                made["machineConfig"] = outcomeFacts(status: outcome.status, reason: outcome.reason, statusFile: CloudMachineConfig.statusPath, log: CloudMachineConfig.logPath)
            }
            return CloudHandlerRules().fields("cloud_handler_created", ["request": requestFacts(request), "made": made.compacted])
        }
    }

    /// The request's facts as `action.run` result fields, next to the machine's (nil: none yet).
    static func newMachineFields(_ request: CloudMachineRequest, _ session: CloudMachineSession?) -> [String: ActionResultValue] {
        CloudHandlerRules().fields("cloud_handler_new_machine_fields", ["request": requestFacts(request), "machine": session.map(machineFacts) as Any].compacted)
    }

    /// The New Cloud Workspace flow over this app's services (cx-lu8f).
    /// `startedByPerson`: true only for an action invoked with origin user; any other create (a Retry or Dismiss
    /// button of the progress view, which carries no gesture origin) asks the person first. `capCard`: a refusal at
    /// the plan's cap shows its card; false for a CLI's or agent's run, which hears the refusal at once (cmux#32725).
    /// `reveals`: the run may change the view (a person's, or one with `--focus`): a machine made with no
    /// window showing its creation still opens its workspace in one. Without it the workspace waits,
    /// out of the sidebar, until the person opens the machine (`unopenedCloudWorkspaces`).
    static func creationFlow(_ context: AppActionContext, startedByPerson: Bool = false, capCard: Bool = true, askedBy: String? = nil, reveals: Bool = false,
                             proceed: @escaping (CloudMachineCreation) throws -> Void = { _ in }) -> CloudCreationFlow {
        let cloud = context.services.cloud
        let windows = context.services.windows
        return CloudCreationFlow(
            creations: cloud.creations,
            create: { creation in
                try await cloud.createMachine(name: nil, creation: creation, startedByPerson: startedByPerson, capCard: capCard, askedBy: askedBy,
                                               request: creation.request, proceed: { try proceed(creation) })
            },
            open: { session in try await firstWorkspace(on: session, context) },
            show: { id, creation in
                let after = creation.readyAfter.map { String(format: "%.1f s", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? "?"
                cloud.logger.info("new cloud workspace \(id, privacy: .public) on \(creation.session?.machineID ?? "?", privacy: .public) ready after \(after, privacy: .public)")
                // The window that still shows the creation shows its
                // workspace; one that moved on gets it filed quietly. A
                // machine an agent or the CLI made without focus stays out
                // of the sidebar until the person opens it (`unopenedCloudWorkspaces`).
                guard let windowID = creation.windowID, let state = windows.controller(for: windowID)?.state else {
                    if startedByPerson || reveals { windows.reveal(workspaceID: id) }
                    return
                }
                if state.cloudCreation == creation.id {
                    windows.show(workspaceID: id, in: state)
                } else {
                    windows.claim(workspaceID: id, in: state, select: false)
                }
            },
            // The person asked for a machine cmux Pro would allow: one offer; Upgrade opens the
            // refusal's checkout, else pricing. The CLI or Chief gets the plan instead (`startedByPerson`).
            planRequired: { refusal in
                // The dialog sells Pro only; a refusal that needs Max shows as the creation's failure,
                // and a CLI or Chief caller gets its plan (`cloud.plan.required`) to offer a checkout.
                guard refusal.plan == "pro", !refusal.offered else { return }
                // One offer at a time: a repeated create (Retry, the CLI, Chief) adds no second one.
                guard !cloud.proOfferOpen else { return }
                let shown = CloudPresenter.offerPro(refusal.message, in: windows.active?.window) { upgraded in
                    cloud.proOfferOpen = false
                    guard upgraded else { return }
                    // The one paid-plan path: Checkout that returns here, else the refusal's link, else pricing.
                    Task { await context.services.paidPlanUpgrade().start(plan: refusal.plan, source: .cloudRefusal, fallback: refusal.upgradeURL) }
                }
                if shown { cloud.proOfferOpen = true }
            },
            startedByPerson: startedByPerson,
            // The bootstrap and the machine config go with the machine, so a Retry starts each too while it
            // has not started.
            bootstrap: { creation, session in
                let machine = CloudMachineBootstrap.Machine(api: cloud.machineAPI.pinningTeam(creation.request.team), machineID: session.machineID)
                await CloudCreationFlow.startBootstrap(creation, on: machine)
            }
        )
    }

    /// A machine response must still belong to the account and team that started this creation
    /// before it can be attached to the local list. A changed scope tears down the observer and
    /// throws cancellation so CloudCreationFlow does not attach or open the returned machine.
    static func checkCreationScope(_ creation: CloudMachineCreation, in creations: CloudCreations,
                                   expectedUserID: String?, expectedTeamID: String?,
                                   currentUserID: String?, currentTeamID: String?) throws {
        guard let expectedUserID, expectedUserID == currentUserID, expectedTeamID == currentTeamID else {
            creations.end(creation)
            throw CancellationError()
        }
    }

    static func bindAccount(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("palette.auth.signIn", registry, reason: reason) { _ in
            guard !cloud.isSignedIn else { throw ActionFailure(message: CloudStrings.alreadySignedIn) }
            run("sign in", context) { _ = await cloud.auth.signIn() }
        }
        bind("palette.auth.signOut", registry, reason: { cloud.isSignedIn ? nil : CloudStrings.signInFirst }) { _ in
            run("sign out", context) { await cloud.signOut() }
        }
        // Switch Active Team lists the teams as a Cmd-Shift-P step, the current one marked (its `team`
        // argument); the shortcut opens that step too. The switch goes through ActiveTeam, like
        // every other surface (Settings > Accounts has its own team menu).
        bind("openTeamPicker", registry, reason: { cloud.isSignedIn ? nil : CloudStrings.signInFirst }) { invocation in
            let active = cloud.auth.activeTeam
            let facts: [String: Any] = ["teams": active.teams.map { ["id": $0.id, "name": $0.displayName] }, "active": active.id as Any,
                                        "team": invocation["team"]?.stringValue as Any]
            guard let id = try CloudHandlerRules().checked("cloud_handler_team", facts.compacted, valueKey: "select") as? String else { return } // the active team
            run("switch team", context) { try await active.select(id) }
        }
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.cloudTeams else { return otherSuggestions?(source) ?? [] }
            return TeamRowText.suggestions(cloud.auth)
        }
        let otherState = registry.choiceState
        registry.choiceState = { action, target in
            action == "openTeamPicker" ? cloud.auth.teamID : otherState?(action, target)
        }
        bind("cloudDiagnostics", registry, reason: { nil }) { invocation in
            // A person sees one readable line with the report behind Copy
            // details; a CLI or MCP caller gets both as the run's result and
            // nothing shows in the window.
            let byPerson = invocation.origin == .user
            // task-owner: the action run; a capturing caller awaits it through the registry.
            let task: ActionResultWork = Task { @MainActor in
                let report = await diagnostics(context)
                if byPerson { CloudPresenter.show(CloudStrings.diagnosticsTitle, summary: report.summary, details: report.details, in: window(context)) }
                return .success(["summary": .string(report.summary), "details": .string(report.details)])
            }
            context.services.registry.track(result: task)
        }
    }

    /// The Cloud diagnostics: a one-line summary for a person, and the
    /// account, backend and per-machine link state as JSON. No secrets.
    struct Diagnostics {
        var summary: String
        var details: String
    }

    static func diagnostics(_ context: AppActionContext) async -> Diagnostics {
        let cloud = context.services.cloud, machines = context.services.machines
        var rows: [CmuxNextSettings.JSONValue] = []
        for session in machines.cloud {
            var row = AppControl.cloudMachineRow(session, machines)
            row["link_pid"] = .string("app server")
            // The daemon's whole handshake (ghostty commit, capabilities, pid, registry id, generation).
            row.merge(CloudDiagnosticsReport.daemonDetails(session.daemon.store.connectionState, last: session.daemon.store.identity)) { kept, _ in kept }
            rows.append(.object(row))
        }
        let account = CloudDiagnosticsReport.Account(
            backend: cloud.configuration.apiBaseURL.absoluteString, backendKind: String(describing: cloud.configuration.backend),
            signedIn: cloud.isSignedIn, email: cloud.auth.user?.primaryEmail, teamID: cloud.auth.teamID,
            teamName: cloud.auth.teams.first { $0.id == cloud.auth.teamID }?.displayName,
            unavailable: cloud.unavailableReason, lastError: cloud.lastError)
        return Diagnostics(summary: diagnosticsSummary(context, account), details: CloudDiagnosticsReport.details(account, machines: rows))
    }

    /// The first thing that needs the person, else that all is well.
    private static func diagnosticsSummary(_ context: AppActionContext, _ account: CloudDiagnosticsReport.Account) -> String {
        let cloud = context.services.cloud, machines = context.services.machines
        let facts: [String: Any] = [
            "unavailable": cloud.unavailableReason as Any, "signedIn": cloud.isSignedIn,
            "accountLabel": CloudDiagnosticsReport.accountLabel(account),
            "machines": machines.cloud.map { session -> [String: Any] in
                let compat = machines.compatibility(of: session.daemon).flatMap { $0.level == .current ? nil : CloudStrings.compatibility($0) }
                return ["title": session.machine.title, "failure": session.stage.failure as Any, "compatibility": compat as Any].compacted
            },
        ]
        let summary = CloudHandlerRules().ask("cloud_handler_diagnostics", facts.compacted)?["summary"]
        return CloudHandlerRules.text(CloudHandlerRules.decodeSaid(summary ?? NSNull()))
    }

    static func bindSignInRecovery(into registry: ActionRegistry, cloud: CloudService) { CloudSignInRecovery(pending: cloud.signedOutCreation, signIn: { await cloud.auth.signIn() }, hasCurrentList: { cloud.hasCurrentList(within: .seconds(30)) }, isSignedIn: { cloud.isSignedIn }, refresh: { await cloud.refresh() }).bind(into: registry) } // HQ #4884
}

// The Cloud toggle (#26062): with `cloud.newWorkspacesInCloud` on, a person's New Workspace runs the
// New Cloud Workspace flow on a new machine of its own, in their folder copied there (as Move to
// Cloud copies a chat's) or in the machine's empty folder. Agent chats in it run on that machine.
extension CloudHandlers {
    /// Starts it for `invocation` when the toggle applies, Cloud can create a machine and `window`
    /// can show its progress; otherwise asks for nothing and says why New Workspace stays here.
    static func startNewWorkspaceInCloud(_ invocation: ActionInvocation, cwd: String?, window: WindowState?, _ services: AppServices) -> CloudNewWorkspacePlan.Outcome {
        let cloud = services.cloud, setting = CloudNewWorkspaceSetting(), root = services.settings?.snapshot.root ?? .object([:])
        // The app server's create copies no folder: the workspace opens in the machine's empty folder.
        guard let plan = CloudNewWorkspacePlan(inCloud: setting.inCloud(in: root), inheritsFolder: false, cwd: cwd,
                                               byPerson: invocation.isPersonsOwnRun, namesMachineOrCommand: invocation["machine"] != nil || invocation["command"] != nil)
        else { return .thisMac(notice: nil) }
        switch CloudNewWorkspacePlan.route(unavailableReason: cloud.unavailableReason, signedIn: cloud.isSignedIn, hasWindow: window != nil) {
        case .cloud: break
        case .thisMac(.unavailable(let reason)): return .thisMac(notice: CloudStrings.newWorkspaceOpenedHere(reason))
        case .thisMac(.signedOut): return .thisMac(notice: CloudStrings.newWorkspaceOpenedHere(CloudStrings.signInFirst))
        case .thisMac(.noWindow): return .thisMac(notice: CloudStrings.newWorkspaceOpenedHere(CloudStrings.newWorkspaceNoWindow))
        }
        // A second press while this window's machine is still on its way shows that one again: one paid machine per wait.
        if let window, let pending = pendingNewWorkspaceCreation(in: cloud.creations, window: window.id) {
            window.page = nil
            window.cloudCreation = pending.id
            return .started
        }
        let userID = cloud.auth.user?.id, teamID = cloud.auth.teamID, profile = window?.profileID ?? .defaultProfile
        let checkScope: @MainActor (CloudMachineSession) throws -> Void = { session in
            try Task.checkCancellation()
            guard let userID, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else {
                // An account or team switch ends the creation, as `checkCreationScope` does, so no row stays stuck at ready.
                if let creation = cloud.creations.all.first(where: { $0.session === session }) { cloud.creations.end(creation) }
                throw CancellationError()
            }
        }
        creationFlow(AppActionContext(services: services), startedByPerson: true, proceed: { creation in
            try checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                   currentUserID: cloud.auth.user?.id, currentTeamID: cloud.auth.teamID)
        }).start(in: window, existing: nil) { session in
            try checkScope(session)
            let name = session.machine.title
            guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudMoveStrings.notConnected(name)) }
            var cwd: String?
            let folder = try await plan.folder(work: services.work)
            try checkScope(session)
            if let folder, let binary = cloud.move.cli {
                guard let socket = await connection.endpoint?.socketPath else { throw ActionFailure(message: CloudMoveStrings.notConnected(name)) }
                let cli = CloudMoveCLI(binary: binary, timeout: cloud.move.timeout)
                do {
                    cwd = try await CloudNewWorkspacePlan.copy(folder, workRoots: cloud.move.workRoots) { remote in
                        try checkScope(session)
                        let answer = try await cli.seedPush(socket: socket, local: folder.root, remote: remote)
                        return CloudNewWorkspacePlan.CopyAnswer(ok: answer.ok, errorCode: answer.errorCode, error: answer.error)
                    }.chat
                } catch is CancellationError {
                    throw CancellationError()
                } catch CloudNewWorkspacePlan.CopyFailure.outdated {
                    throw ActionFailure(message: CloudMoveStrings.outdatedMachine(name))
                } catch CloudNewWorkspacePlan.CopyFailure.failed(let detail) {
                    throw ActionFailure(message: CloudMoveStrings.syncFailed(name, detail))
                } catch {
                    throw ActionFailure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)))
                }
            }
            try checkScope(session)
            let key = WorkspaceKey.generate()
            if let room = services.machines.local.store.profile(profile), let sessionID = session.daemon.store.registryID,
               let home = services.machines.local.connection {
                try await DaemonConnection.retryingLateReplies(PinWorkspaceRequest.command) {
                    try await home.pinWorkspace(session: sessionID, key: key, to: room.id)
                }
            }
            try checkScope(session)
            try await WorkspaceCreation.create(key, name: folder.map { URL(fileURLWithPath: $0.root).lastPathComponent }, on: connection, repair: session.emptyWorkspaces) { _ = try await WorkspaceCreation.firstTerminal(in: $0, cwd: cwd, on: connection) }
            return key.rawValue
        }
        return .started
    }

    /// The toggle's creation window `id` shows that has not opened its workspace yet (requesting,
    /// booting, or failed with Retry), if any.
    static func pendingNewWorkspaceCreation(in creations: CloudCreations, window id: String) -> CloudMachineCreation? {
        creations.shown(in: id).last { $0.open != nil && $0.workspaceID == nil && !$0.isTornDown }
    }
}
