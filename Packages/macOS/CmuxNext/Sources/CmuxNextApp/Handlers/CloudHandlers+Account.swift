import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCloudCredentials
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextControl
import CmuxNextDaemon
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
            guard let session = target, session.daemon.connection != nil else {
                if target == nil, origin(of: invocation) == .user, window != nil {
                    beginWorkspaceSetup(context, window: window, askedBy: invocation.callerAgentSession)
                    return
                }
                // A new machine, or one still on its way: show its progress
                // now. An ended app link connects again on this gesture, and
                // a paused machine resumes (idle auto-pause).
                target?.attach(origin: connectOrigin(for: invocation))
                creationFlow(context, startedByPerson: invocation.origin == .user, askedBy: invocation.callerAgentSession,
                             reveals: invocation.allowsViewChange).start(in: window, existing: target)
                // A CLI or agent hears that the workspace comes later: its machine is starting or connecting.
                result("new cloud workspace", context) {
                    (target.map { machineFields($0.machineID) } ?? [:]).merging(["pending": .bool(true), "status": .string(target == nil ? "creating" : "connecting")]) { field, _ in field }
                }
                return
            }
            result("new cloud workspace", context) {
                // Made in the window it was asked from, like a local New Workspace; a CLI or agent
                // run without focus leaves every window's view as it is.
                let id = await context.services.windows.createWorkspace(on: session.daemon, into: window?.id)
                RemoteGroupHandlers.mark(session: session.daemon.store.registryID) // one group per Cloud machine
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
        guard let session = tabs.sessions[tabs.resolve(chat.id)] ?? chat.agentSession?.session else { return nil }
        let host = tabs.localSessionHost ?? tabs.host
        guard let folder = try? await host.sessionFolder(sessionId: session), folder.isLocal, folder.cwd.hasPrefix("/") else { return nil }
        return folder.cwd
    }

    static func beginWorkspaceSetup(_ context: AppActionContext, window: WindowState?, askedBy: String?, chat: TabModel? = nil) {
        runTracked("new Cloud workspace", context) {
            let cloud = context.services.cloud, services = context.services
            let userID = cloud.auth.user?.id, teamID = cloud.auth.teamID
            let availability = CloudWorkspaceSetupWizard.CredentialAvailability.resolve(
                teamID: cloud.auth.teamID, supportsFileRoute: AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: cloud.configuration.linkSource, isSignedIn: true, passesLogin: true),
                passesLogin: CloudStartChat.passesHarnessLoginHere)
            let present: (CmuxDialogSpec) async -> CmuxDialogAnswer = { spec in
                let scope: CmuxDialogScope = services.windows.active?.window.map(CmuxDialogScope.window) ?? .app
                return await CmuxDialogCenter.shared.present(spec, in: scope)
            }
            let wizard = CloudWorkspaceSetupWizard(), pick = await CloudChatPick(services: services).read(folder: await chatFolder(chat, services), tab: chat)
            // Environments live in the cmux-next backend's CloudDO: only its Cloud path lists them.
            let supportsEnvironments = cloud.configuration.linkSource == .appServer
            let environments = supportsEnvironments ? await cloud.appServerEnvironmentOptions() : []
            // The plan's sizes, from the last machine list: only the `/api/vm` create takes a size
            // (the app server's create refuses one for now), so its path shows no size choice.
            let sizes = cloud.configuration.linkSource == .legacy
                ? cloud.planSizes : []
            guard let plan = try await wizard.choosePlan(availability: availability,
                scopeIsCurrent: { cloud.auth.user?.id == userID && cloud.auth.teamID == teamID },
                supportsRepository: cloud.configuration.linkSource == .legacy, suggested: pick?.repo,
                environments: environments, supportsEnvironments: supportsEnvironments,
                sizes: sizes, autosized: pick?.autosize != nil && pick?.repo != nil, present: present) else { return }
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
                    guard let windowID = window?.id, let originalWindow = services.windows.controller(for: windowID)?.window else {
                        throw CancellationError()
                    }
                    try await cloud.codexBroker.run(machineID: session.machineID,
                        scope: .init(userID: userID, teamID: teamID), confirmed: true,
                        presentDeviceCode: { prompt in
                            await CloudPresenter.presentCodexDeviceCode(prompt, in: .window(originalWindow))
                        })
                    return
                }
                let transfer = CloudCredentialTransfer(provider: .claude,
                    machineID: session.machineID, teamID: teamID, userID: userID, openTerminal: { [weak services] line in
                        await services?.openLocalProviderLogin(line) ?? false
                    })
                try await transfer.run(api: cloud.machineAPI, currentTeamID: { cloud.auth.teamID },
                                       currentUserID: { cloud.auth.user?.id }, confirmed: true,
                                       callerOwnsVM: { [machineID = session.machineID] in try await cloud.callerOwnsVM(machineID) })
            }
        }
    }

    /// A retryable failure is still waiting. Mirroring removes the progress row normally;
    /// explicit teardown ends the wizard even when it already opened a workspace.
    static func workspaceSetupReadiness(_ creation: CloudMachineCreation, in creations: CloudCreations) -> CloudWorkspaceSetupWizard.Readiness {
        if creation.isTornDown { return .ended }
        if creation.workspaceID != nil { return .ready }
        return creations.creation(creation.id) == nil ? .ended : .waiting
    }

    /// Normal row removal keeps the clone wait alive; teardown wakes it without a result.
    static func workspaceSetupCompletion(_ creation: CloudMachineCreation) -> (completion: CloudMachineBootstrap.Completion?, ended: Bool) {
        (creation.bootstrapCompletion, creation.isTornDown)
    }

    /// The machine New Cloud Workspace opens on, nil for a new one. It keeps the
    /// active-window fallback for any caller (it only opens a workspace, and with
    /// no machine a CLI run starts a new one), but a named `--target machine:<id>`
    /// that is not there is refused, never answered with a new machine. With several
    /// machines and none in view, it opens on the first one in sidebar order that is
    /// connected or ``CloudMachine/takesUnnamedWorkspaces`` (the workspace joins that
    /// machine's group); only with none a new VM starts and bills (Lawrence msg 1334).
    static func workspaceMachine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> CloudMachineSession? {
        if invocation.target?.kind == .machine { return try machine(invocation, context) }
        return (try? machine(invocation, context, fallsBack: true)) ?? context.services.machines.cloud.first { $0.daemon.connection != nil || $0.machine.takesUnnamedWorkspaces }
    }

    // MARK: cloud new-machine with options

    /// The invocation's `name`, `size`, `persistent`, `bootstrap`, `bootstrapScript`, `machineConfig` and `repo`. Reads no
    /// file: the script is loaded off the main thread before the create.
    static func newMachineRequest(_ invocation: ActionInvocation) throws -> CloudMachineRequest {
        // A text flag given with no value (`--bootstrap-script` last on the line) arrives as `true`:
        // refuse it rather than make a machine without what was asked.
        for name in ["name", "size", "bootstrap", "bootstrapScript", "machineConfig", "repo"] where invocation[name] != nil && invocation[name]?.stringValue == nil {
            switch name {
            case "machineConfig": throw ActionFailure(message: CloudStrings.machineConfigUnreadable("--machine-config"))
            case "size": throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(createSizes.keys.sorted().joined(separator: ", ")))
            case "name": throw ActionFailure(message: CloudStrings.laneNeedsName)
            case "repo": throw ActionFailure(message: CloudStrings.repoUnrecognized)
            default: throw ActionFailure(message: CloudStrings.bootstrapScriptRequired)
            }
        }
        var request = CloudMachineRequest()
        if let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard CloudMachineRequest.isPlainName(name) else { throw ActionFailure(message: CloudStrings.machineNameInvalid) }
            request.name = name
        }
        if let size = invocation["size"]?.stringValue {
            guard let (_, memory) = createSizes[size] else { throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(createSizes.keys.sorted().joined(separator: ", "))) }
            request.size = size
            request.memoryMb = memory
        }
        request.persistent = invocation["persistent"]?.boolValue ?? (invocation["persistent"]?.stringValue == "true")
        let kind = invocation["bootstrap"]?.stringValue ?? "none", path = invocation["bootstrapScript"]?.stringValue
        guard kind == "none" || kind == "lane" else { throw ActionFailure(message: CloudStrings.bootstrapScriptRequired) }
        if kind == "lane" || path != nil {
            // A script alone runs as a plain bootstrap; `lane` also names the lane host.
            guard let path, !path.isEmpty else { throw ActionFailure(message: CloudStrings.bootstrapScriptRequired) }
            request.bootstrapPath = expandingHome(path)
            request.bootstrapKind = kind == "lane" ? .lane : .plain
        }
        if let config = invocation["machineConfig"]?.stringValue {
            guard !config.isEmpty else { throw ActionFailure(message: CloudStrings.machineConfigUnreadable(config)) }
            request.machineConfigPath = expandingHome(config)
        }
        if request.bootstrapKind == .lane, request.name == nil { throw ActionFailure(message: CloudStrings.laneNeedsName) }
        if let spec = invocation["repo"]?.stringValue {
            do { request.repo = try CloudMachineRepo.parse(spec) } catch let invalid as CloudMachineRepo.Invalid {
                // The spec is never echoed: it may carry a token.
                switch invalid {
                case .credentialsInURL: throw ActionFailure(message: CloudStrings.repoCredentialsInURL)
                case .invalidRef: throw ActionFailure(message: CloudStrings.repoInvalidRef)
                case .unrecognized: throw ActionFailure(message: CloudStrings.repoUnrecognized)
                }
            }
        }
        return request
    }

    /// A quoted `~/boot.sh` reaches the app unexpanded.
    static func expandingHome(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst()) : path
    }

    /// The `machine_config` answer of a start (``CloudMachineConfig``): its status and how to read it.
    static func machineConfigAnswer(_ outcome: CloudMachineBootstrap.Outcome, machineID: String) -> ActionResultValue {
        var answer: [String: ActionResultValue] = [
            "status": .string(outcome.status), "status_file": .string(CloudMachineConfig.statusPath), "log": .string(CloudMachineConfig.logPath),
            "check": .string("cmux cloud file-read --target machine:\(machineID) --path \(CloudMachineConfig.statusPath)"),
        ]
        if let reason = outcome.reason { answer["reason"] = .string(reason) }
        return .object(answer)
    }

    /// Loads the bootstrap script before anything is created (an unreadable script costs no
    /// machine), starts the creation (its progress shows like any New Cloud Machine), then runs
    /// the bootstrap on the machine the server returned. Answers the machine's facts, the
    /// request's, `bootstrap` and `enrollment`. After ``createdMachineWait`` it answers
    /// `pending`, and the create and the bootstrap go on (`cloud list-machines` shows the
    /// machine; its bootstrap status file says how far it got).
    static func createRequested(_ request: CloudMachineRequest, flow: CloudCreationFlow, window: WindowState?, _ context: AppActionContext) {
        let creations = context.services.cloud.creations, work = context.services.work
        result("new Cloud machine", context, pendingAfter: createdMachineWait, pending: newMachineFields(request, nil).merging(["status": .string("creating")]) { _, new in new }) {
            var request = request
            do { request.script = try await request.loadScript(work: work) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                throw ActionFailure(message: CloudStrings.bootstrapScriptUnreadable(unreadable.path))
            }
            do { request.machineConfig = try await request.loadMachineConfig(work: work) } catch let unreadable as CloudMachineRequest.ScriptUnreadable {
                throw ActionFailure(message: CloudStrings.machineConfigUnreadable(unreadable.path))
            }
            let creation = flow.start(in: window, existing: nil, request: request)
            if case .failed(let reason)? = await settledCreation(creation, in: creations) { throw ActionFailure(message: "new Cloud machine: \(reason)") }
            guard let session = creation.session else { throw ActionFailure(message: CloudStrings.createDeclined) }
            var fields = createdMachineFields(session, workspaceID: creation.workspaceID).merging(newMachineFields(request, session.machine)) { _, new in new }
            var bootstrap: [String: ActionResultValue] = ["status": .string("none")]
            if let script = request.script, let outcome = creation.bootstrap {
                bootstrap = ["status": .string(outcome.status), "kind": .string(script.kind.rawValue), "log": .string(CloudMachineBootstrap.logPath),
                             "status_file": .string(CloudMachineBootstrap.statusPath),
                             "check": .string("cmux cloud file-read --target machine:\(session.machineID) --path \(CloudMachineBootstrap.statusPath)")]
                if let reason = outcome.reason { bootstrap["reason"] = .string(reason) }
            }
            fields["bootstrap"] = .object(bootstrap)
            if let repo = request.repo {
                // The clone runs in the bootstrap; its result (cloned, updated, kept, failed, needs_github)
                // lands later in the status file's `repo`, which `check` reads.
                fields["repo"] = .object(["spec": .string(repo.spec), "url": .string(repo.url), "dir": .string("~/" + repo.directory),
                                          "check": bootstrap["check"] ?? .string("none")])
            }
            if request.machineConfig != nil, let outcome = creation.machineConfig {
                fields["machine_config"] = machineConfigAnswer(outcome, machineID: session.machineID)
            }
            var enrollment = newMachineEnrollment(request, session.machine)
            if request.persistent, session.machine.idlePauseMinutes != 0 {
                // The create and the PUT after it both left the default: say how to finish.
                enrollment["pending"] = .array([.string("idle-pause: cmux cloud set-idle-pause --target machine:\(session.machineID) --minutes off")]
                    + (enrollment["pending"].flatMap { if case .array(let items) = $0 { items } else { nil } } ?? []))
            }
            fields["enrollment"] = .object(enrollment)
            return fields
        }
    }

    /// `cloud new-machine --size` -> (vCPUs, MiB) as the server's size ladder makes them from the
    /// memory a create sends (web/services/vms/images/sizes.ts: the smallest row with that memory),
    /// so the answer says what the machine gets. `resize-machine` sets vCPUs itself (``sizes``).
    static let createSizes: [String: (Int, Int)] = ["small": (2, 4096), "medium": (4, 8192), "large": (8, 16384), "xlarge": (12, 24576)]

    /// The request's facts as `action.run` result fields, next to the machine's. `persistent`
    /// is what the server stored, not what was asked (`persistent_requested`); a `pending`
    /// answer, with no machine yet, has no `persistent`.
    static func newMachineFields(_ request: CloudMachineRequest, _ machine: CloudMachine?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["persistent_requested": .bool(request.persistent)]
        if let name = machine?.displayName ?? request.name { fields["name"] = .string(name) }
        let asked = request.size.flatMap { size in createSizes[size].map { (size, $0.0, $0.1) } }
        if let size = asked?.0 ?? machine?.size?.name { fields["size"] = .string(size) }
        if let cpu = machine?.size?.cpu ?? asked?.1 { fields["cpu"] = .int(cpu) }
        if let memory = machine?.size?.memoryMb ?? asked?.2 { fields["memory_mb"] = .int(memory) }
        if let machine {
            fields["persistent"] = .bool(machine.idlePauseMinutes == 0)
            if let minutes = machine.idlePauseMinutes { fields["idle_pause_minutes"] = .int(minutes) }
        }
        if let address = machine?.address?.ipv4 ?? machine?.address?.ipv6 { fields["address"] = .string(address) }
        return fields
    }

    /// What is left to make a lane machine a fleet host: the ssh route and acpmux peer from the
    /// Mac that drives it (`cloud enroll-machine`), and the registry entries leo-workspace keeps
    /// (`tools/lane-vm-enroll`).
    static func newMachineEnrollment(_ request: CloudMachineRequest, _ machine: CloudMachine) -> [String: ActionResultValue] {
        var answer: [String: ActionResultValue] = ["done": .array([]), "pending": .array([.string("ssh-route"), .string("acpmux-peer"), .string("fleet-registry")])]
        let named = request.name.map { " --name \($0)" } ?? ""
        answer["enroll_command"] = .string("cmux cloud enroll-machine --target machine:\(machine.id)\(named)")
        guard request.bootstrapKind == .lane, request.bootstrapPath != nil, let name = request.name else { return answer }
        let address = machine.address?.ipv4.map { " --address \($0)" } ?? ""
        answer["registry_command"] = .string("tools/lane-vm-enroll \(name) \(machine.id)\(address) --apply")
        return answer
    }

    /// The New Cloud Workspace flow over this app's services (cx-lu8f).
    /// `startedByPerson`: true only for an action invoked with origin user;
    /// any other create (a Retry or Dismiss button of the progress view,
    /// which carries no gesture origin) asks the person first.
    /// `reveals`: the run may change the view (a person's, or one with `--focus`): a machine made with no
    /// window showing its creation still opens its workspace in one. Without it the workspace waits,
    /// out of the sidebar, until the person opens the machine (`unopenedCloudWorkspaces`).
    static func creationFlow(_ context: AppActionContext, startedByPerson: Bool = false, askedBy: String? = nil, reveals: Bool = false,
                             proceed: @escaping (CloudMachineCreation) throws -> Void = { _ in }) -> CloudCreationFlow {
        let cloud = context.services.cloud
        let windows = context.services.windows
        return CloudCreationFlow(
            creations: cloud.creations,
            create: { creation in
                try await cloud.createMachine(name: nil, creation: creation, startedByPerson: startedByPerson, askedBy: askedBy,
                                               request: creation.request, proceed: { try proceed(creation) })
            },
            open: { session in defer { RemoteGroupHandlers.mark(session: session.daemon.store.registryID) }; return try await firstWorkspace(on: session, context) },
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
            let active = cloud.auth.activeTeam, teams = active.teams
            guard !teams.isEmpty else { throw ActionFailure(message: CloudStrings.noTeams) }
            guard let id = invocation["team"]?.stringValue, let team = teams.first(where: { $0.id == id || $0.displayName == id }) else {
                throw ActionFailure.invalidTarget(CloudStrings.noSuchTeam(invocation["team"]?.stringValue ?? ""))
            }
            guard team.id != active.id else { return } // the active team is a no-op
            run("switch team", context) { try await active.select(team.id) }
        }
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.cloudTeams else { return otherSuggestions?(source) ?? [] }
            return cloud.auth.teams.map { ActionEnumCase(value: $0.id, title: $0.displayName) }
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
            row["link_pid"] = .string(await session.link?.pid.map(String.init) ?? (session.appLink == nil ? "none" : "app server"))
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
        if let reason = cloud.unavailableReason { return reason }
        guard cloud.isSignedIn else { return CloudStrings.signInFirst }
        for session in machines.cloud {
            if let failure = session.stage.failure { return "\(session.machine.title): \(failure)" }
            if let compat = machines.compatibility(of: session.daemon), compat.level != .current {
                return "\(session.machine.title): \(CloudStrings.compatibility(compat))"
            }
        }
        return CloudStrings.diagnosticsAllWell(CloudDiagnosticsReport.accountLabel(account))
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
        let canCopy = cloud.move.cli != nil && cloud.configuration.linkSource == .legacy
        guard let plan = CloudNewWorkspacePlan(inCloud: setting.inCloud(in: root), inheritsFolder: canCopy && setting.folder(in: root) == .inherit, cwd: cwd,
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
            defer { RemoteGroupHandlers.mark(session: session.daemon.store.registryID) } // one group per Cloud machine
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
