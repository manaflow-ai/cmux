import AppKit

/// A row whose title inline rename edits in place (`SidebarInlineRename`): a list row (`SidebarRowView`) or a pinned
/// workspace's band row (`SidebarItemRowView`). Every geometry is in the row's own coordinates.
@MainActor protocol SidebarRenameTitle: NSView {
    /// Where the title draws.
    var titleFrame: NSRect { get }
    /// The title's font: the editor types in it.
    var titleFont: NSFont { get }
    /// Where the title's first glyph starts on its baseline (the pen origin); nil: no title to edit.
    var titlePenOrigin: NSValue? { get }
    /// The title's ink: the editor's text keeps it.
    var titleInk: NSColor? { get }
    /// Where the editor may end, before the row's trailing controls and marks.
    var titleEditMaxX: CGFloat { get }
    /// Hides the title while the editor draws in its place, and shows it again.
    func setTitleHidden(_ hidden: Bool)
}

extension SidebarRowView: SidebarRenameTitle {}
