import AppKit

@MainActor
struct MainWindowRouteSnapshot {
    let windowId: UUID
    let tabManager: TabManager
    let window: NSWindow?
    let sidebar: SidebarState
    let sidebarSelection: SidebarSelectionState
    let dock: MainWindowRouteDockState?
}
