import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups

// Creation (new machine, new cloud workspace), sign in/out, team picker,
// and diagnostics.
extension CloudHandlers {
    static func bindCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        bind("newCloudMachine", registry, reason: reason) { invocation in
            let request = try newMachineRequest(invocation)
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            let flow = creationFlow(context, startedByPerson: invocation.origin == .user, askedBy: invocation.callerAgentSession)
            guard request.isDefault else { return createRequested(request, flow: flow, window: window, context) }
            // The new machine's progress shows in the window at once; its
            // first workspace opens there when its daemon is ready.
            reportCreatedMachine(flow.start(in: window, existing: nil), context)
        }
        bind("newCloudWorkspace", registry, reason: reason) { invocation in
            let target = try workspaceMachine(invocation, context)
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            guard let session = target, session.daemon.connection != nil else {
                // A new machine, or one still on its way: show its progress
                // now. An ended app link connects again on this gesture, and
                // a paused machine resumes (idle auto-pause).
                target?.attach(origin: connectOrigin(for: invocation))
                creationFlow(context, startedByPerson: invocation.origin == .user, askedBy: invocation.callerAgentSession).start(in: window, existing: target)
                // A CLI or agent hears that the workspace comes later: its machine is starting or connecting.
                result("new cloud workspace", context) {
                    (target.map { machineFields($0.machineID) } ?? [:]).merging(["pending": .bool(true), "status": .string(target == nil ? "creating" : "connecting")]) { field, _ in field }
                }
                return
            }
            result("new cloud workspace", context) {
                let id = await context.services.windows.createWorkspace(on: session.daemon)
                RemoteGroupHandlers.mark(session: session.daemon.store.registryID) // one group per Cloud machine
                guard let id else { throw ActionFailure(message: CloudStrings.notConnected) }
                show(id, context)
                return machineFields(session.machineID, ["workspace_id": .string(id)])
            }
        }
    }

    /// The machine New Cloud Workspace opens on, nil for a new one. It keeps the
    /// active-window fallback for any caller (it only opens a workspace, and with
    /// no machine a CLI run starts a new one), but a named `--target machine:<id>`
    /// that is not there is refused, never answered with a new machine.
    static func workspaceMachine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> CloudMachineSession? {
        if invocation.target?.kind == .machine { return try machine(invocation, context) }
        return try? machine(invocation, context, fallsBack: true)
    }

    // MARK: cloud new-machine with options

    /// The invocation's `name`, `size`, `persistent`, `bootstrap` and `bootstrapScript`. Reads no
    /// file: the script is loaded off the main thread before the create.
    static func newMachineRequest(_ invocation: ActionInvocation) throws -> CloudMachineRequest {
        // A text flag given with no value (`--bootstrap-script` last on the line) arrives as `true`:
        // refuse it rather than make a machine without what was asked.
        for name in ["name", "size", "bootstrap", "bootstrapScript"] where invocation[name] != nil && invocation[name]?.stringValue == nil {
            switch name {
            case "size": throw ActionFailure(message: CloudStrings.sizeMustBeOneOf(createSizes.keys.sorted().joined(separator: ", ")))
            case "name": throw ActionFailure(message: CloudStrings.laneNeedsName)
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
            // A quoted `~/boot.sh` reaches the app unexpanded.
            request.bootstrapPath = path == "~" || path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst()) : path
            request.bootstrapKind = kind == "lane" ? .lane : .plain
        }
        if request.bootstrapKind == .lane, request.name == nil { throw ActionFailure(message: CloudStrings.laneNeedsName) }
        return request
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
    static func creationFlow(_ context: AppActionContext, startedByPerson: Bool = false, askedBy: String? = nil) -> CloudCreationFlow {
        let cloud = context.services.cloud
        let windows = context.services.windows
        return CloudCreationFlow(
            creations: cloud.creations,
            create: { creation in
                let session = try await cloud.createMachine(name: nil, creation: creation, startedByPerson: startedByPerson, askedBy: askedBy, request: creation.request)
                // The bootstrap belongs to the create, so a Retry after a failed create starts it too.
                if let script = creation.request.script {
                    creation.noteBootstrap(await script.start(name: creation.request.name, on: CloudMachineBootstrap.Machine(api: cloud.api.pinningTeam(creation.request.team), machineID: session.machineID)))
                }
                return session
            },
            open: { session in defer { RemoteGroupHandlers.mark(session: session.daemon.store.registryID) }; return try await firstWorkspace(on: session, context) },
            show: { id, creation in
                let after = creation.readyAfter.map { String(format: "%.1f s", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? "?"
                cloud.logger.info("new cloud workspace \(id, privacy: .public) on \(creation.session?.machineID ?? "?", privacy: .public) ready after \(after, privacy: .public)")
                // The window that still shows the creation shows its
                // workspace; one that moved on gets it filed quietly.
                guard let windowID = creation.windowID, let state = windows.controller(for: windowID)?.state else {
                    windows.reveal(workspaceID: id)
                    return
                }
                if state.cloudCreation == creation.id {
                    windows.show(workspaceID: id, in: state)
                } else {
                    windows.claim(workspaceID: id, in: state, select: false)
                }
            }
        )
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
}
