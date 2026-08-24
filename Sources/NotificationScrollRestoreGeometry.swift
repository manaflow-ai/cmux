import CmuxTerminalCore
import GhosttyKit

/// Authoritative terminal geometry tied to one absolute Ghostty row space.
struct NotificationScrollRestoreGeometry: Sendable {
    let scrollbar: GhosttyScrollbar
    let rowSpaceRevision: UInt64

    init(scrollbar: GhosttyScrollbar, rowSpaceRevision: UInt64) {
        self.scrollbar = scrollbar
        self.rowSpaceRevision = rowSpaceRevision
    }

    init(c: ghostty_surface_scrollbar_s) {
        scrollbar = GhosttyScrollbar(total: c.total, offset: c.offset, len: c.len)
        rowSpaceRevision = c.row_space_revision
    }

}
