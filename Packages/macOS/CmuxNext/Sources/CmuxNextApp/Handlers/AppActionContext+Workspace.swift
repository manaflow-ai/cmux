import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Target resolution for workspace, group, window, and sidebar handlers.
/// Each throws an `ActionFailure` instead of silently doing nothing.
extension AppActionContext {
    var store: DaemonStore { services.activeDaemon.store }
    var activeWindow: WindowController? { services.windows.active }

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
    /// group of the targeted or shown workspace.
    func group(_ invocation: ActionInvocation) throws -> WorkspaceGroupModel {
        if usesPersonalGroups { return try personalGroup(invocation) }
        try require(DaemonCapabilities.workspaceGroups)
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .workspaceGroup }
        if let explicit {
            guard let group = store.group(WorkspaceGroupID(rawValue: explicit.id)) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceGroup(explicit.id))
            }
            return group
        }
        guard let id = scope(invocation).workspace?.group, let group = store.group(id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup)
        }
        return group
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
            throw ActionFailure.invalidTarget(RefusalStrings.noWindow(ref.id))
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

    func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw ActionFailure(message: RefusalStrings.couldNotOpen(url.absoluteString)) }
    }

    /// Brings the app forward unless launched with `CMUX_NEXT_NO_ACTIVATE=1`.
    func activateApp() {
        if !services.environment.noActivate { NSApp.activate() }
    }
}
