import AppKit
import CmuxNextDesign

/// A pinned workspace's band row renames in place as a workspace list row does (Lawrence msg 19583: "double clicking
/// pinned workspaces to rename has problem"): a double-click opens the list's one editor (`SidebarInlineRename`) over
/// the title, its text on the title's first glyph and baseline, and nothing in the row moves.
extension SidebarItemRowView: SidebarRenameTitle {
    var titleFont: NSFont { title.font ?? SidebarStyle.titleFont }

    /// The chrome label draws its text its padding (the alignment inset) in from its frame, the first baseline
    /// `firstBaselineOffsetFromTop` below its top.
    var titlePenOrigin: NSValue? {
        guard !style.isIconOnly, title.frame.width > 0 else { return nil }
        return NSValue(point: NSPoint(x: title.frame.minX + title.alignmentRectInsets.left, y: title.frame.minY + title.firstBaselineOffsetFromTop))
    }

    var titleInk: NSColor? { title.textColor }

    /// The editor ends where the title does: before the hover more button, the trailing dot, the status and the count.
    var titleEditMaxX: CGFloat { title.frame.maxX - title.alignmentRectInsets.right }

    func setTitleHidden(_ hidden: Bool) {
        isRenaming = hidden
        title.isHidden = style.isIconOnly || hidden
    }

    /// Whether `event`, a press on the row's fill, is the second click of a double-click that renames: a plain one on
    /// a row that names an open workspace, outside edit mode.
    func pressRenames(_ event: NSEvent) -> Bool {
        event.clickCount == 2 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty && onRename != nil
            && info.workspace != nil && !isEditing && !style.isIconOnly && style != .favorite && style != .chip
    }
}
