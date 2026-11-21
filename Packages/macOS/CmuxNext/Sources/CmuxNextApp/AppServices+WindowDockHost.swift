import AppKit
import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextSettings

// The window dock (plans/cmux-next/docked-workspace-DESIGN.md, user 2026-11-05): one-line forwards to the App's owners.
extension AppServices: WindowDockHost {
    func dockFrame(_ invocation: ActionInvocation) -> (any WindowDockFrame)? { try? AppActionContext(services: self).window(invocation) }
    var dockActiveFrame: (any WindowDockFrame)? { windows.active }
    func dockFrame(owning id: String) -> (any WindowDockFrame)? { windows.registry.value.owner(of: id).flatMap(windows.controller(for:)) }
    func dockTargetWorkspace(_ invocation: ActionInvocation) -> String? { (try? AppActionContext(services: self).workspace(invocation))?.model.id }
    func dockPaneWorkspace(_ invocation: ActionInvocation) -> String? { TabMoves.paneWorkspace(AppActionContext(services: self).daemonPane(invocation), services: self) }
    func dockMovePane(_ invocation: ActionInvocation, into id: String) -> Bool { TabMoves.pane(AppActionContext(services: self).daemonPane(invocation), toWorkspace: id, services: self) }
    func dockMovePaneToNewWorkspace(_ invocation: ActionInvocation) async -> String? { await TabMoves.paneToNewWorkspace(AppActionContext(services: self).daemonPane(invocation), services: self) }
    var chiefDockEdge: DockEdge { DockEdge(rawValue: settings?.snapshot.chiefDockEdge ?? ChiefDockSetting.edgeDefault) ?? .left }
    var chiefDockOpensBeside: Bool { (settings?.snapshot.chiefDockOpenBeside ?? ChiefDockSetting.openBesideDefault) && !home.dock.isClassic }
    var chiefHomeIsClassic: Bool { home.dock.isClassic }
    func chiefHome(in windowID: String) -> String? { windowHomes.home(in: windowID)?.id }
    func chiefMakeHome(in windowID: String) async -> String? { await windowHomes.show(in: windowID)?.id }
    func chiefShowHome() -> Bool { AppActions.showHome(self) }
    func chiefFocusComposer() { AppActions.focusDockComposer(self) }
    func chiefBringAppForward() -> Bool { defer { NSApp.activate(); windows.active?.window?.makeKeyAndOrderFront(nil) }; return !NSApp.isActive }
}
