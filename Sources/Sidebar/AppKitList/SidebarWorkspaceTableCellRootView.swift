import AppKit

/// Stable native root installed once for a reusable fallback table cell.
@MainActor
final class SidebarWorkspaceTableCellRootView: NSView {
    override var isFlipped: Bool { true }
}
