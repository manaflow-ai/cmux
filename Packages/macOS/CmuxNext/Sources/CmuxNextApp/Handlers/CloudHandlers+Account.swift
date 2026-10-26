import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings

// Creation (new machine, new cloud workspace), sign in/out, team picker,
// and diagnostics.
extension CloudHandlers {
    static func bindCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        bind("newCloudMachine", registry, reason: reason) { invocation in
            // The new machine's progress shows in the window at once; its
            // first workspace opens there when its daemon is ready.
            let creation = creationFlow(context, startedByPerson: invocation.origin == .user, askedBy: invocation.callerAgentSession).start(in: invocation.allowsViewChange ? context.services.windows.active?.state : nil, existing: nil)
            reportCreatedMachine(creation, context)
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

    /// The New Cloud Workspace flow over this app's services (cx-lu8f).
    /// `startedByPerson`: true only for an action invoked with origin user;
    /// any other create (a Retry or Dismiss button of the progress view,
    /// which carries no gesture origin) asks the person first.
    static func creationFlow(_ context: AppActionContext, startedByPerson: Bool = false, askedBy: String? = nil) -> CloudCreationFlow {
        let cloud = context.services.cloud
        let windows = context.services.windows
        return CloudCreationFlow(
            creations: cloud.creations,
            create: { creation in try await cloud.createMachine(name: nil, creation: creation, startedByPerson: startedByPerson, askedBy: askedBy) },
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
