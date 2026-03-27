import AppKit
import Bonsplit
import SwiftUI

/// Transparent overlay that intercepts right-clicks to show an AppKit context menu.
/// The underlying NSView is created once and never replaced by SwiftUI updates.
private final class SidebarContextMenuPassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right-click events for context menu display.
        // All other events pass through to the SwiftUI content below.
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown else {
            return nil
        }
        return bounds.contains(point) ? self : nil
    }
}

/// NSViewRepresentable that installs a stable AppKit NSMenu on a sidebar row.
/// Menu content is built at right-click time via NSMenuDelegate, not during
/// SwiftUI rendering. This decouples the menu from the observation pipeline.
struct SidebarContextMenuHost: NSViewRepresentable {
    let workspace: Workspace
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let setSelectionToTabs: () -> Void
    let index: Int
    let depth: Int

    func makeCoordinator() -> SidebarContextMenuController {
        SidebarContextMenuController()
    }

    func makeNSView(context: Context) -> NSView {
        let view = SidebarContextMenuPassthroughView()
        let menu = NSMenu()
        menu.delegate = context.coordinator
        view.menu = menu
#if DEBUG
        dlog("contextMenu.host.makeNSView workspace=\(workspace.id.uuidString.prefix(5))")
#endif
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.workspace = workspace
        coord.tabManager = tabManager
        coord.notificationStore = notificationStore
        coord.index = index
        coord.depth = depth
        let selBinding = $selectedTabIds
        coord.readSelectedTabIds = { selBinding.wrappedValue }
        coord.writeSelectedTabIds = { selBinding.wrappedValue = $0 }
        let idxBinding = $lastSidebarSelectionIndex
        coord.readLastSidebarSelectionIndex = { idxBinding.wrappedValue }
        coord.writeLastSidebarSelectionIndex = { idxBinding.wrappedValue = $0 }
        coord.setSelectionToTabs = setSelectionToTabs
    }
}
