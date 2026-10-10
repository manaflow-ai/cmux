import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

// Creation (new machine, new cloud workspace), sign in/out, team picker,
// and diagnostics.
extension CloudHandlers {
    static func bindCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        bind("newCloudMachine", registry, reason: reason) { invocation in
            // The new machine's progress shows in the window at once; its
            // first workspace opens there when its daemon is ready.
            creationFlow(context, startedByPerson: invocation.origin == .user).start(in: invocation.allowsViewChange ? context.services.windows.active?.state : nil, existing: nil)
        }
        bind("newCloudWorkspace", registry, reason: reason) { invocation in
            let target = try? machine(invocation, context)
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            guard let session = target, session.daemon.connection != nil else {
                // A new machine, or one still on its way: show its progress
                // now. An ended app link connects again on this gesture.
                if let target, target.appLink != nil { target.connect(origin: connectOrigin(for: invocation)) }
                creationFlow(context, startedByPerson: invocation.origin == .user).start(in: window, existing: target)
                return
            }
            run("new cloud workspace", context) {
                if let id = await context.services.windows.createWorkspace(on: session.daemon) { show(id, context) }
            }
        }
    }

    /// The New Cloud Workspace flow over this app's services (cx-lu8f).
    /// `startedByPerson`: the person's own gesture (a Retry click is one).
    static func creationFlow(_ context: AppActionContext, startedByPerson: Bool = true) -> CloudCreationFlow {
        let cloud = context.services.cloud
        let windows = context.services.windows
        return CloudCreationFlow(
            creations: cloud.creations,
            create: { creation in try await cloud.createMachine(name: nil, creation: creation, startedByPerson: startedByPerson) },
            open: { session in try await firstWorkspace(on: session, context) },
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
        bind("openTeamPicker", registry, reason: { cloud.isSignedIn ? nil : CloudStrings.signInFirst }) { _ in
            let teams = cloud.auth.teams
            guard !teams.isEmpty else { throw ActionFailure(message: CloudStrings.noTeams) }
            CloudPresenter.choose(CloudStrings.teamPickerTitle, teams.map { ($0.displayName, $0.id) }, selected: cloud.auth.teamID,
                                  in: window(context)) { id in
                guard let id, id != cloud.auth.teamID else { return }
                cloud.auth.selectTeam(id)
                run("switch team", context) { await cloud.refresh() }
            }
        }
        bind("cloudDiagnostics", registry, reason: { nil }) { _ in
            run("cloud diagnostics", context) {
                CloudPresenter.show(CloudStrings.diagnosticsTitle, await diagnostics(context), copyable: true, in: window(context))
            }
        }
    }

    /// Account, backend, tunnel, and per-machine link state. No secrets.
    static func diagnostics(_ context: AppActionContext) async -> String {
        let cloud = context.services.cloud
        var lines = [
            "backend: \(cloud.configuration.apiBaseURL.absoluteString) (\(cloud.configuration.backend))",
            "signed in: \(cloud.isSignedIn)" + (cloud.auth.user?.primaryEmail.map { " as \($0)" } ?? ""),
            "team: \(cloud.auth.teamID ?? "none")",
            "unavailable: \(cloud.unavailableReason ?? "no")",
            "last error: \(cloud.lastError ?? "none")",
        ]
        for session in context.services.machines.cloud {
            let pid = await session.link?.pid.map(String.init) ?? (session.appLink == nil ? "none" : "app server")
            lines.append("\(session.machineID) \(session.machine.title): \(session.effectiveStatus.rawValue), stage \(session.stage.name), "
                + "daemon \(session.daemon.store.connectionState), link pid \(pid), workspaces \(session.daemon.store.workspaces.count)")
            if let compat = context.services.machines.compatibility(of: session.daemon) {
                lines.append("  cmux-tui \(compat.versionLabel): \(compat.level.rawValue)"
                    + (compat.level == .current ? "" : "; \(CloudStrings.compatibility(compat))"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
