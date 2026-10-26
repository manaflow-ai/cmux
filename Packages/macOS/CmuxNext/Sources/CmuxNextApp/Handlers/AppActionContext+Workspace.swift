import AppKit
import os
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextPages
import CmuxNextDesign
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

    /// Opens `url` in its app off the main thread (cx-050n). Refuses at once a URL with no scheme, or one the kept
    /// Launch Services answer says no app opens; an answer not kept yet is asked on the system lane for the next run,
    /// and the open goes ahead: when no app opens it, the refusal notice shows then.
    func open(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else { throw ActionFailure(message: RefusalStrings.couldNotOpen(url.absoluteString)) }
        if scheme == "http" || scheme == "https" { LinkRouter.shared.open(url); return }
        let handler = WorkspaceQuery<URL?>.defaultApplication(toOpen: url)
        if let kept = services.workspaceQueries.cached(handler), kept == nil {
            throw ActionFailure(message: RefusalStrings.couldNotOpen(url.absoluteString))
        }
        services.workspaceQueries.prefetch([handler], priority: .bestEffort)
        NSWorkspace.shared.openInBackground(url) { [weak services = self.services] opened in
            guard !opened, let services else { return }
            services.refusalHUD.show(RefusalStrings.couldNotOpen(url.absoluteString), in: services.windows.active?.window ?? NSApp.keyWindow)
        }
    }

    /// Brings the app forward unless launched with `CMUX_NEXT_NO_ACTIVATE=1`
    /// or the run may not change this client's view.
    func activateApp() {
        guard ActionRunScope.viewChangeAllowed() else { return }
        WindowActivation.activateApp()
    }
}
