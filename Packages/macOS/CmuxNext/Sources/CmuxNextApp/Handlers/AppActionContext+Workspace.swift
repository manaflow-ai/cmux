import AppKit
import os
import CmuxNextCompat
import CmuxNextPages
import CmuxNextDesign
import CmuxNextActions
import CmuxNextDaemon

/// Target resolution for workspace, group, window, and sidebar handlers.
/// Each throws an `ActionFailure` instead of silently doing nothing.
extension AppActionContext {
    var store: DaemonStore { services.activeDaemon.store }
    var activeWindow: WindowController? { services.windows.active }

    /// The window a control caller's new workspace opens in (#32989): its own (a Chief turn's, the window the
    /// person prompted it from) while that window is open; nil for a person, or when it closed.
    func callerWindow(_ invocation: ActionInvocation) -> WindowController? {
        guard let id = invocation.callerWindow, services.windows.registry.value.window(id)?.isOpen == true else { return nil }
        return services.windows.controller(for: id)
    }

    /// The window a new workspace of `invocation` opens in: the caller's (``callerWindow(_:)``), else the active one.
    func createWindow(_ invocation: ActionInvocation) -> WindowController? { callerWindow(invocation) ?? activeWindow }

    /// The workspace a create of `invocation` is placed next to: its target, else the one the caller's window
    /// shows (a Chief's create goes where it was prompted, #32989), else the active window's. Nil when the
    /// caller's window shows none: the create goes to that window (``createWindow(_:)``), never the active one's.
    func createAnchorIfAny(_ invocation: ActionInvocation) throws -> WorkspaceModel? {
        let targeted = (invocation.target ?? invocation["workspace"]?.targetValue)?.kind == .workspace
        if !targeted, let caller = callerWindow(invocation) {
            return caller.state.workspaceID.flatMap(services.workspace(id:)).flatMap { $0.key == nil ? nil : $0 }
        }
        return try workspace(invocation).model
    }

    /// ``createAnchorIfAny(_:)`` for a create that needs an anchor; refused when there is none.
    func createAnchor(_ invocation: ActionInvocation) throws -> WorkspaceModel {
        guard let anchor = try createAnchorIfAny(invocation) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        return anchor
    }

    /// Throws unless the daemon serves `capability`.
    func require(_ capability: String) throws {
        let daemon = services.activeDaemon
        guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
    }

    /// The targeted workspace (target, `workspace` argument) or the one the
    /// active window shows.
    func workspace(_ invocation: ActionInvocation) throws -> (model: WorkspaceModel, key: WorkspaceKey) {
        guard let model = scope(invocation).workspace else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        guard let key = model.key else { throw ActionFailure.needsDaemonCapability("workspace-registry-v1") }
        return (model, key)
    }

    /// The active window's workspaces in sidebar order (ungrouped first,
    /// then each group). Each window lists only its own workspaces.
    var sidebarOrder: [WorkspaceModel] {
        let all = store.sidebarSections.flatMap(\.workspaces)
        guard let window = activeWindow else { return all }
        let members = Set(services.windows.registry.members(of: window.state.id))
        return all.filter { members.contains($0.id) }
    }

    /// The targeted workspace group (target, `group` argument), else the
    /// group of the targeted or shown workspace. Workspace groups are
    /// personal (the home session's); without personal state there are none.
    func group(_ invocation: ActionInvocation) throws -> WorkspaceGroupModel {
        guard usesPersonalGroups else {
            throw ActionFailure(message: services.machines.local.personalStateUnavailableReason)
        }
        return try personalGroup(invocation)
    }

    /// The window named by the target or `window` argument (`WindowState.id`),
    /// else the active window.
    func window(_ invocation: ActionInvocation) throws -> WindowController {
        let ref = [invocation.target, invocation["window"]?.targetValue].compactMap { $0 }.first { $0.kind == .window }
        guard let ref else {
            guard let active = activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
            return active
        }
        guard let controller = services.windows.controllers.first(where: { $0.state.id == ref.id }) else {
            throw ActionFailure.notFound(RefusalStrings.noWindow(ref.id))
        }
        return controller
    }

    /// The active window's sidebar, which turns intents into daemon commands
    /// with an optimistic sidebar update (the same path as clicks and drags).
    func sidebar() throws -> SidebarBridge {
        guard let sidebar = activeWindow?.sidebar else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        return sidebar
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Refuses at once when no app opens `url` (a LaunchServices database lookup); the open itself
    /// runs off the main thread (cx-050n).
    func open(_ url: URL) throws {
        if url.scheme == "http" || url.scheme == "https" { LinkRouter.shared.open(url); return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw ActionFailure(message: RefusalStrings.couldNotOpen(url.absoluteString))
        }
        NSWorkspace.shared.openInBackground(url) { opened in
            if !opened { Logger(subsystem: "com.cmuxterm.app.next", category: "actions").error("open failed after its app was found") }
        }
    }

    /// Brings the app forward unless launched with `CMUX_NEXT_NO_ACTIVATE=1`
    /// or the run may not change this client's view.
    func activateApp() {
        guard ActionRunScope.viewChangeAllowed() else { return }
        WindowActivation.activateApp()
    }
}
