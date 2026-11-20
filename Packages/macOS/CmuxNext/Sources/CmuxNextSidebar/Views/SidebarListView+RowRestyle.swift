import AppKit
import CmuxNextDesign

// The row restyle's part of the list (`SidebarRowRestyle`, `experiments.sidebarRowStyle`, off by default): the indent
// step, the members' one step under their header, the full-width hover band and the keyboard focus. Off, every value
// here is today's.
extension SidebarListView {
    private var restyles: Bool { DesignSettings.shared.sidebarRowStyle.isOn }

    /// One nesting step: the group gutter; under the restyle one icon column, so a nested header's leading chevron
    /// sits under its parent's members' titles.
    var restyleIndentStep: CGFloat { restyles ? SidebarRowRestyle.memberIndent : SidebarStyle.groupGutter }

    /// How far a group's members' content sits right of its header's under the restyle (their titles under the
    /// header's, after its chevron); 0 off.
    var restyleMembersStep: CGFloat { restyles ? SidebarRowRestyle.memberIndent : 0 }

    /// `restyleMembersStep` for a group's member row; 0 for a header, a row standing for its group and ungrouped rows.
    func restyleMemberStep(for row: SidebarRow) -> CGFloat {
        if case .group = row.key { return 0 }
        return row.group != nil && !row.standsForGroup ? restyleMembersStep : 0
    }

    /// `row`'s view frame (list coordinates): its content frame (`contentFrame(for:)`), or under the restyle that frame
    /// widened to start at the list's inset (a group header that reaches further left over its rail keeps its reach),
    /// so the row's band spans the full width inside the row's own bounds; the row draws its content
    /// `contentIndent(for:)` in. Hit testing, drags, the sticky header and every view frame read this one.
    func frame(for row: SidebarRow) -> NSRect {
        let content = contentFrame(for: row)
        guard restyles, content.minX > inset else { return content }
        return NSRect(x: inset, y: content.minY, width: content.maxX - inset, height: content.height)
    }

    /// How far `row`'s content sits right of its view frame's leading edge (`SidebarRowView.contentIndent`); 0 off.
    func contentIndent(for row: SidebarRow) -> CGFloat {
        guard restyles else { return 0 }
        return max(0, contentFrame(for: row).minX - inset)
    }

    /// Group members' content step under a drop into a group (the drag's card shape and slot underlay): the indent
    /// rule's step-in, or under the restyle none, since every row's frame spans the full width there.
    func membersStepIn(depth: Int) -> CGFloat {
        restyles ? 0 : indent.offset(level: depth, width: indentWidth)
    }

    /// The rect a pointer hovers or clicks a row in: its frame, or under the restyle its full-width band (from the
    /// list's inset to its end, whatever its indent, `SidebarRowRestyle.bandRect`).
    func hoverFrame(for row: SidebarRow) -> NSRect {
        let frame = frame(for: row)
        guard restyles else { return frame }
        return NSRect(x: inset, y: frame.minY, width: max(0, frame.maxX - inset), height: frame.height)
    }

    /// `experiments.sidebarRowStyle` changed: every made row lays out and paints again (the one observer is the
    /// sidebar's, `SidebarView+Observation`); the list lays its rows out again for the new indent.
    func restyleChanged() {
        if !restyles { restyleKeyboard = false }
        for row in rowViews.values {
            row.needsLayout = true
            row.needsDisplay = true
        }
        needsLayout = true
    }

    // Keyboard focus for the restyle's selected row: the list taking the keyboard on a key (an arrow from an item
    // above, Tab; not a click) counts as the keyboard's until a click (`SidebarRowRestyle.noteMouse`); letting the
    // keyboard go takes the focus away.
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took, NSApp.currentEvent?.type == .keyDown { SidebarRowRestyle.noteKey(in: self) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { SidebarRowRestyle.focusLeft(self) }
        return gave
    }
}
