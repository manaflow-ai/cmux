import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

/// Home's close rules in the app (S15, cx-qno.3). The store refuses every
/// close of its home workspace (`home_not_closable`); the app refuses
/// first, with a localized reason, so menus, the palette, the sidebar and
/// the CLI agree and no raw store error shows. A Close Workspace that names
/// no workspace while a top page shows is refused too: behind the page the
/// window's workspace is parked (or is the hidden home), so the close would
/// hit a workspace the user does not see (TOP-SECTION-ITEMS-ARE-PAGES).
@MainActor
enum HomeRules {
    /// Adds the close reasons to `closeWorkspace` (after it is bound).
    static func install(_ services: AppServices) {
        let registry = services.registry
        let previous = registry.action(for: "closeWorkspace")?.targetUnavailableReason
        ActionTargetReasons.set("closeWorkspace", in: registry) { [weak services] invocation in
            if let reason = previous?(invocation) { return reason }
            guard let services else { return nil }
            return closeWorkspaceReason(invocation, services: services)
        }
    }

    /// Why Close Workspace must not run for `invocation`, or nil.
    static func closeWorkspaceReason(_ invocation: ActionInvocation, services: AppServices) -> String? {
        if let target = invocation.target ?? invocation["workspace"]?.targetValue, target.kind == .workspace {
            return isHome(services.workspace(id: target.id)) ? RefusalStrings.homeNotClosable : nil
        }
        guard let window = services.windows.active else { return nil }
        if window.shownTopPage != nil { return RefusalStrings.topPageIsNotAWorkspace }
        return isHome(window.state.workspaceID.flatMap(services.workspace(id:))) ? RefusalStrings.homeNotClosable : nil
    }

    static func isHome(_ workspace: WorkspaceModel?) -> Bool {
        workspace?.kind == SidebarMapping.homeKind
    }
}
