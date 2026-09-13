import AppKit

extension NSPasteboard.PasteboardType {
    /// A sidebar-only row identity; the destination also validates the source outline.
    static let cloudSidebarRow = Self("com.cmux.cloud-sidebar-row")
}
