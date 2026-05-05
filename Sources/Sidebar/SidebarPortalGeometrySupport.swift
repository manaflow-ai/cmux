import AppKit

@MainActor
func synchronizeSidebarPortalGeometry(in window: NSWindow?) {
    guard let window else { return }
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
    TerminalWindowPortalRegistry.synchronizeExternalGeometryNow(for: window)
    BrowserWindowPortalRegistry.synchronizeExternalGeometryNow(for: window)
}
