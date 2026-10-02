import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon

/// Cloud and account actions over the kept Cloud library (`CmuxNextCloud`):
/// Stack sign-in, `/api/vm`, and each machine's daemon tree. A machine is
/// the invocation's `machine:` target (a machine section's context menu or
/// CLI `--target machine:vm-…`), else the machine of the active window's
/// workspace, else the only machine. Work runs in tasks; failures surface
/// as a sheet (and in the log), refusals reach the control socket.
enum CloudHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let cloud = context.services.cloud!
        let reason: @MainActor () -> String? = { cloud.unavailableReason }
        let signedInReason: @MainActor () -> String? = { cloud.unavailableReason ?? (cloud.isSignedIn ? nil : CloudStrings.signInFirst) }
        bindMachineActions(into: registry, context: context, reason: signedInReason)
        bindCreation(into: registry, context: context, reason: signedInReason)
        bindAccount(into: registry, context: context, reason: reason)
        registry.bindUnavailable(["palette.mobileConnect"], ActionFailure(message: CloudStrings.mobilePairing))
        // Any catalog row added later without a handler stays covered.
        registry.bindUnavailable(registry.unboundActionIDs(in: [.cloud]), ActionFailure(message: MiscHandlerStrings.cloud))
    }

    /// Binds `id` with an availability reason and a throwing body.
    static func bind(_ id: ActionID, _ registry: ActionRegistry, reason: @escaping @MainActor () -> String?,
                     _ body: @escaping @MainActor (ActionInvocation) throws -> Void) {
        let bound = registry.bind(id, unavailable: reason, invoke: { [weak registry] invocation in
            do { try body(invocation) } catch { registry?.refuse(String(describing: error)) }
        })
        assert(bound, "\(id) is not in the action catalog")
    }

    // MARK: Resolution

    /// The Cloud machine an invocation acts on.
    static func machine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> CloudMachineSession {
        let machines = context.services.machines
        if let target = invocation.target, target.kind == .machine {
            guard let session = machines.session(target.id) else { throw ActionFailure(message: RefusalStrings.notShownInAnyWindow(target.description)) }
            return session
        }
        if let state = context.services.windows.active?.state, let session = machines.session(state.machineID) { return session }
        if machines.cloud.count == 1, let only = machines.cloud.first { return only }
        throw ActionFailure(message: CloudStrings.noMachine)
    }

    /// The active cmux window (sheets attach there, never to a helper panel).
    static func window(_ context: AppActionContext) -> NSWindow? { context.services.windows.active?.window }

    /// Runs Cloud work off the action; a thrown error becomes a sheet.
    static func run(_ label: String, _ context: AppActionContext, _ work: @escaping @MainActor () async throws -> Void) {
        let logger = context.services.cloud.logger
        Task {
            do { try await work() } catch {
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
                return ActionWorkFailure("\(label): \(error)")
            }
        }
        context.services.registry.track(task)
    }

    /// Shows `workspaceID` in the active window (or a new one).
    static func show(_ workspaceID: String, _ context: AppActionContext) {
        let windows = context.services.windows!
        if let state = windows.active?.state { windows.show(workspaceID: workspaceID, in: state) } else { windows.openWindow(workspaces: [workspaceID]) }
    }

    /// The machine's first workspace, created (with a terminal) when it has none.
    static func firstWorkspace(on session: CloudMachineSession, _ context: AppActionContext) async throws -> String {
        let daemon = session.daemon
        guard daemon.connection != nil else { throw ActionFailure(message: CloudStrings.notConnected) }
        if let first = daemon.store.workspaces.first { return first.id }
        guard let id = await context.services.windows.createWorkspace(on: daemon) else { throw ActionFailure(message: CloudStrings.notConnected) }
        return id
    }

    /// The existing workspace and pane where a Cloud terminal should land.
    /// Keep the durable workspace key on the spawn request so terminals stay
    /// attached to the machine after daemon handle ids are recycled.
    @MainActor static func terminalAnchor(on session: CloudMachineSession, _ context: AppActionContext) async throws -> (id: String, key: WorkspaceKey, pane: PaneModel) {
        let id = try await firstWorkspace(on: session, context)
        guard let workspace = session.daemon.store.workspaces.first(where: { $0.id == id }),
              let key = workspace.key,
              let pane = workspace.screens.first?.panes.first else {
            throw ActionFailure(message: CloudStrings.notConnected)
        }
        return (id, key, pane)
    }

    static func commandArgument(_ invocation: ActionInvocation) throws -> String {
        guard let command = invocation["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw ActionFailure(message: CloudStrings.commandRequired)
        }
        return command
    }
}
