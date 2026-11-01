import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import CmuxNextRemoteView

/// Cloud and account actions over the kept Cloud library (`CmuxNextCloud`):
/// Stack sign-in, `/api/vm`, and each machine's daemon tree. A machine is
/// the invocation's `machine:` target (a machine section's context menu or
/// CLI `--target machine:vm-…`), else, for a person's own gesture only, the
/// machine of the active window's workspace, else the only machine. Work runs in tasks; failures surface
/// as a sheet (and in the log), refusals reach the control socket.
enum CloudHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let cloud = context.services.cloud
        let reason: @MainActor () -> String? = { cloud.unavailableReason }
        let signedInReason: @MainActor () -> String? = { cloud.unavailableReason ?? (cloud.isSignedIn ? nil : CloudStrings.signInFirst) }
        bindMachineActions(into: registry, context: context, reason: signedInReason)
        bindBrowserActions(into: registry, context: context, reason: signedInReason)
        CloudGitHubHandlers.bind(into: registry, context: context, reason: signedInReason)
        bindNetworkActions(into: registry, context: context, reason: signedInReason)
        bindDomainActions(into: registry, context: context, reason: signedInReason)
        bindListActions(into: registry, context: context)
        CloudStartSession.bind(into: registry, context: context, reason: signedInReason)
        bindCreation(into: registry, context: context, reason: { cloud.unavailableReason })
        bindAccount(into: registry, context: context, reason: reason)
        bindMove(into: registry, context: context)
        bindSignInRecovery(into: registry, cloud: cloud)
        CloudMachineStage.gatePowerActions(into: registry, context: context)
        // Any catalog row added later without a handler stays covered.
        registry.bindUnavailable(registry.unboundActionIDs(in: [.cloud]), ActionFailure(message: MiscHandlerStrings.cloud))
    }

    /// Binds `id` with an availability reason and a throwing body.
    static func bind(_ id: ActionID, _ registry: ActionRegistry, reason: @escaping @MainActor () -> String?,
                     _ body: @escaping @MainActor (ActionInvocation) throws -> Void) {
        let bound = registry.bind(id, unavailable: reason, invoke: { [weak registry] invocation in
            do { try body(invocation) } catch { registry?.refuse(RefusalStrings.describe(error)) }
        })
        assert(bound, "\(id) is not in the action catalog")
    }

    static func bindMachineCreation(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        let signedOutCreation = cloud.signedOutCreation
        let bound = registry.bindEffect("newCloudMachine", requires: nil, unavailable: reason) { invocation in
            let request = try CloudHandlers.newMachineRequest(invocation)
            let actionOrigin = CloudHandlers.origin(of: invocation)
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            // The chat the person asked from, read now: sign-in may finish after focus moved.
            let chat = CloudChatPick.chatTab(invocation, context.services)
            let start: @MainActor () -> ActionWorkFailure? = {
                guard cloud.isSignedIn else { return ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.signInFirst) }
                if let reason = cloud.unavailableReason { return ActionWorkFailure(refusal: .unavailable, reason: reason) }
                if let window, context.services.windows.controller(for: window.id) == nil {
                    return ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined)
                }
                if request.isDefault, actionOrigin == .user, window != nil {
                    CloudHandlers.beginWorkspaceSetup(context, window: window, askedBy: invocation.callerAgentSession, chat: chat)
                    return nil
                }
                let flow = CloudHandlers.creationFlow(context, startedByPerson: actionOrigin == .user,
                                         askedBy: invocation.callerAgentSession, reveals: invocation.allowsViewChange)
                guard request.isDefault else {
                    CloudHandlers.createRequested(request, flow: flow, window: window, context)
                    return nil
                }
                CloudHandlers.reportCreatedMachine(flow.start(in: window, existing: nil), context)
                return nil
            }
            guard !cloud.isSignedIn else {
                signedOutCreation.cancel()
                return registry.trackedWorkEffect(cancellationFailure: ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined), start: start)
            }
            guard actionOrigin == .user else {
                return .refused(CloudStrings.signInFirst)
            }
            let expected = signedOutCreation.reserve()
            return registry.trackedWorkEffect(cancellationFailure: ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined), authorize: {
                let authorized = await signedOutCreation.perform(expected: expected,
                    signIn: { await cloud.auth.signIn() }, resume: {})
                guard authorized, cloud.isSignedIn else {
                    return ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.signInFirst)
                }
                if let reason = cloud.unavailableReason {
                    return ActionWorkFailure(refusal: .unavailable, reason: reason)
                }
                if let window, context.services.windows.controller(for: window.id) == nil {
                    return ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined)
                }
                return nil
            }, cancelAuthorization: { signedOutCreation.cancel(expected: expected) }, start: start)
        }
        assert(bound, "newCloudMachine is not in the action catalog")
    }

    // MARK: Resolution

    /// The Cloud machine an invocation acts on.
    ///
    /// Only a person's own gesture in this app may mean "the machine I'm looking at" (the active
    /// window's machine, else the only one). A CLI, MCP, script, page or remote run must name
    /// its machine (`--target machine:<id>`): an agent's `cloud kill-machine --confirm true`
    /// never kills whatever machine the window happens to show. `fallsBack` keeps the old
    /// fallback for an action whose miss costs nothing (New Cloud Workspace).
    static func machine(_ invocation: ActionInvocation, _ context: AppActionContext, fallsBack: Bool = false) throws -> CloudMachineSession {
        let machines = context.services.machines
        if let target = invocation.target, target.kind == .machine {
            // The Cloud machine id (`cloud diagnostics`, `new-machine`), or the `machine_…`
            // resource id `cmux machine list` prints for a connected one.
            guard let session = machines.session(target.id)
                ?? machines.cloud.first(where: { $0.daemon.identity?.machineResourceID?.rawValue == target.id }) else {
                throw ActionFailure.notFound(CloudStrings.unknownMachine(target.id))
            }
            return session
        }
        guard origin(of: invocation) == .user || fallsBack else { throw ActionFailure(message: CloudStrings.noMachine) }
        if let state = context.services.windows.active?.state, let session = machines.session(state.machineID) { return session }
        if machines.cloud.count == 1, let only = machines.cloud.first { return only }
        throw ActionFailure(message: CloudStrings.noMachine)
    }

    /// Who started the run `invocation` belongs to. A nested perform builds its
    /// invocation with the default `user` origin, so the enclosing run's scope
    /// (``ActionRunScope``) decides: a composite action from the CLI stays the CLI's.
    static func origin(of invocation: ActionInvocation) -> ActionOrigin {
        ActionRunScope.current?.origin ?? invocation.origin
    }

    /// The origin of a connect an invocation starts: `user` only for the
    /// user's own gesture in this app (click, menu, palette, key); the CLI,
    /// MCP, a script, another client or a page connects as `script`.
    static func connectOrigin(for invocation: ActionInvocation) -> CloudLinkOrigin {
        invocation.origin == .user ? .user : .script
    }

    /// The active cmux window (sheets attach there, never to a helper panel).
    static func window(_ context: AppActionContext) -> NSWindow? { context.services.windows.active?.window }

    /// Runs Cloud work off the action; a thrown error becomes a sheet.
    static func run(_ label: String, _ context: AppActionContext, _ work: @escaping @MainActor () async throws -> Void) {
        let logger = context.services.cloud.logger
        Task {
            do { try await work() } catch CloudMachineCreateFlow.Failure.declined {
                // The person said no in the confirmation: nothing to report.
                logger.info("\(label, privacy: .public): declined")
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                CloudPresenter.failure(error, in: window(context))
            }
        }
    }

    /// Runs a Cloud mutation while reporting completion to action.run callers.
    /// Interactive callers still receive the usual failure sheet.
    static func runTracked(_ label: String, _ context: AppActionContext, _ work: @escaping @MainActor () async throws -> Void) {
        let logger = context.services.cloud.logger
        let interactive = !context.services.registry.isCapturingRefusal
        let task: ActionWork = Task { @MainActor in
            do {
                try await work()
                return nil
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if interactive { CloudPresenter.failure(error, in: window(context)) }
                return ActionWorkFailure("\(label): \(CloudStrings.errorText(error))")
            }
        }
        context.services.registry.track(task)
    }

    /// Shows `workspaceID` in the active window (or a new one).
    static func show(_ workspaceID: String, _ context: AppActionContext) {
        let windows = context.services.windows
        if let state = windows.active?.state { windows.show(workspaceID: workspaceID, in: state) } else { windows.openWindow(workspaces: [workspaceID]) }
    }

    @MainActor static func reveal(_ surface: SurfaceID, in pane: PaneModel, workspaceID: String, _ context: AppActionContext) {
        let select: (PaneController) -> Void = { controller in
            // Through the run's view-change gate (ActionRunScope).
            controller.selectWhenReported(surface: surface)
        }
        if let controller = context.services.paneController(for: pane) {
            select(controller)
            show(workspaceID, context)
            return
        }
        show(workspaceID, context)
        Task { @MainActor in
            // concurrency-allow: the observation task is cancelled by the bounded race below
            let mounted = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    await waitForPaneController(pane, context)
                }
                group.addTask {
                    // wakeup-allow: one-shot mount deadline; this task is cancelled when the observation wins
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
            if mounted, let controller = context.services.paneController(for: pane) { select(controller) }
        }
    }

    @MainActor
    private static func waitForPaneController(_ pane: PaneModel, _ context: AppActionContext) async -> Bool {
        for await ready in ObservationStream({ context.services.paneController(for: pane) != nil }) where ready {
            return true
        }
        return false
    }

    /// The machine's first workspace that no other machine also lists (``CloudMachineWorkspace``), created (with a terminal) when it has none.
    private static func firstWorkspaceResult(on session: CloudMachineSession, _ context: AppActionContext,
                                             beforeCreate: () throws -> Void = {}) async throws -> (id: String, created: Bool) {
        let daemon = session.daemon, machines = context.services.machines
        guard daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
        return try await CloudMachineWorkspace.first(in: daemon.store, notConnected: ActionFailure(message: CloudStrings.notConnected),
                                                     listedElsewhere: { id in machines.daemons.contains { $0 !== daemon && $0.store.workspace(id: id) != nil } },
                                                     beforeCreate: beforeCreate) { await context.services.windows.createWorkspace(on: daemon) }
    }

    static func firstWorkspace(on session: CloudMachineSession, _ context: AppActionContext) async throws -> String {
        try await firstWorkspaceResult(on: session, context).id
    }

    /// Open Desktop (`cloud open-desktop`): the machine's desktop, as cmux Classic shows it, in a
    /// Chromium tab of a new workspace on this Mac at a URL that names the machine
    /// (``RemoteLocalhostService/cloudDesktopURL(machine:)``). Remote localhost routes that page
    /// by its URL through the peer-checked proxy and this Mac's own WireGuard tunnel to the
    /// machine's noVNC (6901 on its loopback), with no TCP port opened on this Mac.
    /// `viewer`: `web` (the default) shows the machine's noVNC page in a Chromium tab; `rd`
    /// shows the remote view pane on the machine's `cmux-rd` host (H.264 over the Cloud tunnel);
    /// `native` shows the remote view pane, the app's own VNC client over the same tunnel. The pane
    /// viewers connect at once for a person and ask first for an agent or the CLI; the web viewer
    /// opens for any local caller (who can already run `cloud exec` on the machine).
    @MainActor static func openDesktop(_ session: CloudMachineSession, _ context: AppActionContext, viewer: String? = nil) throws {
        let services = context.services, title = session.machine.title
        guard session.machine.allows(.desktop), session.machine.address?.ipv4 != nil,
              let url = RemoteLocalhostService.cloudDesktopURL(machine: session.machineID) else {
            throw ActionFailure(message: CloudStrings.desktopUnavailable(title))
        }
        if viewer == "native" || viewer == "rd" {
            guard RemoteViewAvailability().isAvailable else { throw ActionFailure(message: CloudStrings.desktopUnavailable(title)) }
            let rd = viewer == "rd"
            guard let record = RemoteViewTabRecord(host: session.machineID.lowercased(), target: .virtual, mode: .control,
                                                   cloudDesktop: true, cloudRd: rd) else {
                throw ActionFailure(message: CloudStrings.desktopUnavailable(title))
            }
            let name = CloudStrings.desktopWorkspaceName(title), address = record.url.absoluteString
            let api = services.cloud.machineAPI, machineID = session.machineID, cloud = services.cloud
            let unavailable = CloudStrings.desktopUnavailable(title)
            // The person's run scope, captured here: their approval goes on the tab this open makes.
            let scope = ActionRunScope.current, cache = services.cache
            WorkspaceHandlers.createAndShow(services: services, name: name, daemon: services.machines.local) { connection, terminal in
                guard let pane = terminal.pane else { return }
                if rd {
                    // The machine's `cmux-rd` host: started on its display :1 (loopback only), and its
                    // session token fetched over the signed-in Cloud API into memory.
                    let started = try await api.exec(machineID, command: Self.desktopRdStart)
                    // A nonzero exit (127: no start script) means this machine has no cmux-rd host yet;
                    // the host is not in the VM image (development-only today).
                    guard started.exitCode == 0 else { throw ActionFailure(message: unavailable) }
                    let file = try await api.readFile(machineID, path: Self.desktopRdTokenPath)
                    let token = Data(base64Encoded: file.dataBase64).map { String(decoding: $0, as: UTF8.self) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard token.count == 64 else { throw ActionFailure(message: unavailable) }
                    await MainActor.run { cloud.desktopRdTokens[machineID.lowercased()] = token }
                }
                let created = try await connection.newFrontendBrowserTab(url: address, engine: .webkit, in: pane, title: name)
                // The approval goes on the exact tab the daemon made for this open, never on whichever
                // tab first shows the same address (#29208): until then the tab asks for Connect.
                let key = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
                await MainActor.run { cache.personOpenedRemoteView(key, url: record.url, scope: scope) }
                if let surface = terminal.surface { try await connection.closeTab(surface) }
            }
            return
        }
        if let reason = services.cache.browserTabs.cefUnavailableReason() { throw ActionFailure(message: reason) }
        let name = CloudStrings.desktopWorkspaceName(title), address = url.absoluteString
        // On this Mac's daemon: a Cloud machine's own daemon may predate browser tabs.
        WorkspaceHandlers.createAndShow(services: services, name: name, daemon: services.machines.local) { connection, terminal in
            guard let pane = terminal.pane else { return }
            _ = try await connection.newFrontendBrowserTab(url: address, engine: .cef, in: pane, title: name)
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }

    /// The machine's `cmux-rd` desktop host: its start script (a no-op while it runs) and its
    /// session token file (0600), under the `cmux` user's cache.
    static let desktopRdStart = "bash /home/cmux/.cache/cmux-rd/start-rd.sh"
    static let desktopRdTokenPath = "/home/cmux/.cache/cmux-rd/token"

    /// The existing workspace and pane where a Cloud terminal should land.
    /// Keep the durable workspace key on the spawn request so terminals stay
    /// attached to the machine after daemon handle ids are recycled.
    /// `proceed` runs right before each workspace this creates: its throw creates nothing.
    @MainActor static func terminalAnchor(on session: CloudMachineSession, _ context: AppActionContext,
                                          proceed: () throws -> Void = {}) async throws -> (id: String, key: WorkspaceKey, pane: PaneModel) {
        let result = try await firstWorkspaceResult(on: session, context, beforeCreate: proceed)
        let id = result.id
        if let anchor = anchor(id: id, on: session) { return anchor }
        if let anchor = await mirroredAnchor(id: id, on: session) { return anchor }
        // A workspace created from a live empty tree may still be awaiting its
        // mirror; do not issue a duplicate create while that request is pending.
        guard !result.created else { throw ActionFailure(message: CloudStrings.notConnected) }
        try proceed()
        guard let created = await context.services.windows.createWorkspace(on: session.daemon) else {
            throw ActionFailure(message: CloudStrings.notConnected)
        }
        guard let anchor = await mirroredAnchor(id: created, on: session) else {
            throw ActionFailure(message: CloudStrings.notConnected)
        }
        return anchor
    }

    @MainActor static func mirroredAnchor(id: String, on session: CloudMachineSession) async -> (id: String, key: WorkspaceKey, pane: PaneModel)? {
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        let mirrored = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await waitForAnchor(id: id, on: session) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        return mirrored ? anchor(id: id, on: session) : nil
    }

    @MainActor static func anchor(id: String, on session: CloudMachineSession) -> (id: String, key: WorkspaceKey, pane: PaneModel)? {
        guard let workspace = session.daemon.store.workspaces.first(where: { $0.id == id }),
              let key = workspace.key,
              let pane = workspace.screens.first?.panes.first else { return nil }
        return (id, key, pane)
    }

    @MainActor private static func waitForAnchor(id: String, on session: CloudMachineSession) async -> Bool {
        for await ready in ObservationStream({ anchor(id: id, on: session) != nil }) where ready { return true }
        return false
    }

    /// Attaches to `session` (``CloudMachineSession/attach(origin:)``): a
    /// paused machine (cmux Cloud's idle auto-pause) resumes, and the work
    /// waits for its daemon instead of refusing with "not connected". A
    /// legacy machine with no connection reads its record again first, since
    /// the app's copy may still say running. A machine that is not paused
    /// returns at once, as before.
    static func attached(_ session: CloudMachineSession, _ invocation: ActionInvocation,
                         within limit: Duration = .seconds(300)) async throws {
        try requireAttachableState(session)
        await session.refreshIfMaybePaused()
        try requireAttachableState(session)
        session.attach(origin: connectOrigin(for: invocation))
        guard session.resuming else { return }
        let daemon = session.daemon
        _ = await CloudWait.holds(within: limit) { daemon.connection != nil || session.resumeFailure != nil }
        if let failure = session.resumeFailure { throw ActionFailure(message: failure) }
        guard daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
    }

    /// ``attached(_:_:within:)``, then "not connected" unless the daemon
    /// answers: a live machine whose link is down refuses, as before.
    static func attachedAndConnected(_ session: CloudMachineSession, _ invocation: ActionInvocation) async throws {
        try await attached(session, invocation)
        guard session.daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
    }

    /// Whether `session` can take an attach now or after a resume: a legacy
    /// machine with no connection may be paused behind a stale record, so
    /// ``attached(_:_:within:)`` reads it again and decides.
    static func attachable(_ session: CloudMachineSession) -> Bool {
        !session.machine.shownStatus.isChanging && (session.daemon.connection != nil || session.appLink == nil)
    }

    static func requireAttachableState(_ session: CloudMachineSession) throws {
        if let reason = CloudStrings.machineChanging(session.machine.shownStatus) {
            throw ActionFailure(message: reason)
        }
    }

    static func commandArgument(_ invocation: ActionInvocation) throws -> String {
        guard let command = invocation["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw ActionFailure(message: CloudStrings.commandRequired)
        }
        return command
    }
}
