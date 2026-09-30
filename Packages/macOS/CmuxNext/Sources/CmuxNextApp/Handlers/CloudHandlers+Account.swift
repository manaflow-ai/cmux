import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

// Creation (new machine, new cloud workspace), sign in/out, team picker,
// and diagnostics.
extension CloudHandlers {
    static func bindCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud!
        bind("newCloudMachine", registry, reason: reason) { _ in
            run("new cloud machine", context) {
                let session = try await cloud.createMachine(name: nil)
                // The sidebar shows the machine while it provisions; its
                // workspace opens once the daemon is reachable.
                show(try await waitForWorkspace(on: session, context), context)
            }
        }
        bind("newCloudWorkspace", registry, reason: reason) { invocation in
            let session = try? machine(invocation, context)
            run("new cloud workspace", context) {
                let target = if let session { session } else { try await cloud.createMachine(name: nil) }
                if target.daemon.connection == nil {
                    show(try await waitForWorkspace(on: target, context), context)
                } else if let id = await context.services.windows.createWorkspace(on: target.daemon) {
                    show(id, context)
                }
            }
        }
    }

    static func bindAccount(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud!
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

    /// Waits (bounded) for a new machine's daemon, then returns its first
    /// workspace. Provisioning plus the first link usually takes 10-60 s.
    static func waitForWorkspace(on session: CloudMachineSession, _ context: AppActionContext) async throws -> String {
        let store = session.daemon.store
        // concurrency-allow: Observations iteration ends on cancellation, so the group never waits past the deadline
        let loaded = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await waitLoaded(store) }
            // wakeup-allow: one-shot sign-in deadline (240 s) racing the browser callback
            group.addTask { (try? await Task.sleep(for: .seconds(240))) == nil }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        guard loaded else { throw ActionFailure(message: CloudStrings.notConnected) }
        return try await firstWorkspace(on: session, context)
    }

    private static func waitLoaded(_ store: DaemonStore) async -> Bool {
        for await loaded in Observations({ store.isLoaded }) where loaded { return true }
        return false
    }

    /// Account, backend, tunnel, and per-machine link state. No secrets.
    static func diagnostics(_ context: AppActionContext) async -> String {
        let cloud = context.services.cloud!
        var lines = [
            "backend: \(cloud.configuration.apiBaseURL.absoluteString) (\(cloud.configuration.backend))",
            "signed in: \(cloud.isSignedIn)" + (cloud.auth.user?.primaryEmail.map { " as \($0)" } ?? ""),
            "team: \(cloud.auth.teamID ?? "none")",
            "unavailable: \(cloud.unavailableReason ?? "no")",
            "last error: \(cloud.lastError ?? "none")",
        ]
        for session in context.services.machines.cloud {
            let pid = await session.link.pid.map(String.init) ?? "none"
            lines.append("\(session.machineID) \(session.machine.title): \(session.machine.status.rawValue), "
                + "daemon \(session.daemon.store.connectionState), link pid \(pid), workspaces \(session.daemon.store.workspaces.count)")
            if let compat = session.daemon.compatibility {
                lines.append("  cmux-tui \(compat.versionLabel): \(compat.level.rawValue)"
                    + (compat.level == .current ? "" : "; \(CloudStrings.compatibility(compat))"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
