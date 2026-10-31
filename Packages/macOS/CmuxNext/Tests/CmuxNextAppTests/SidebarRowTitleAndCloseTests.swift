import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23 (screenshot 81ad91f2): "need to revert styling back to original, for the X button,
/// and left rail needs better alignment, and text needs to be as left as possible (how it originally was)".
///
/// - A row without an icon starts its title at the leading inset again, where its group header's name
///   starts, not after an empty icon slot (the slot came with c779988d57d, 2026-10-21).
/// - The hover close is the row's own x again: a button at the end of the title's line, centered on it,
///   inside the row's inset (before #23783 put it on the row's top-right corner).
@MainActor @Suite(.serialized) struct SidebarRowTitleAndCloseTests {
    private static let groupID = GroupID("g-left")
    private static let plainID = WorkspaceID("ws-plain")
    private static let memberID = WorkspaceID("ws-member")
    private static let iconID = WorkspaceID("ws-icon")

    /// An ungrouped row with no icon, one with an emoji icon, and a group with one member with no icon.
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let plain = SidebarWorkspace(id: plainID, title: "plain")
        let icon = SidebarWorkspace(id: iconID, title: "with icon", icon: .emoji("😇"))
        let member = SidebarWorkspace(id: memberID, title: "member")
        let group = SidebarGroup(id: groupID, name: "cmux-next app", color: .blue, workspaces: [member])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(plain), .workspace(icon), .group(group)]),
        ], activeWorkspaceID: plainID)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    /// Where a row's title text draws, in the row: the title label draws its glyphs at its own left edge
    /// (`WorkspaceRowView.layoutTextLines`), measured in the fleet gallery's pixels.
    private static func textX(_ row: WorkspaceRowView) -> CGFloat { row.title.frame.minX }

    @Test func aRowWithoutAnIconStartsItsTitleAtTheLeadingInset() throws {
        let sidebar = Self.sidebar()
        let plain = try Self.row(sidebar, Self.plainID)
        #expect(Self.textX(plain) == SidebarStyle.horizontalInset,
                "title at \(Self.textX(plain)) pt, inset \(SidebarStyle.horizontalInset) pt: an empty icon slot pushes it right")
        // A row with an icon keeps the icon at the inset and the text after it.
        let icon = try Self.row(sidebar, Self.iconID)
        #expect(icon.icon.frame.minX == SidebarStyle.horizontalInset)
        #expect(Self.textX(icon) > icon.icon.frame.minX + SidebarStyle.kindGlyphSize, "the title clears the icon")
    }

    @Test func aGroupMembersTitleStartsWhereItsHeadersNameStarts() throws {
        let sidebar = Self.sidebar()
        let list = sidebar.list
        let member = try Self.row(sidebar, Self.memberID)
        let header = try #require(list.rowViews[.group(Self.groupID)] as? GroupHeaderRowView)
        let memberText = list.convert(NSPoint(x: Self.textX(member), y: 0), from: member).x
        let nameText = list.convert(header.name.frame.origin, from: header).x + WorkspaceRowView.labelInset
        let plainText = list.convert(NSPoint(x: Self.textX(try Self.row(sidebar, Self.plainID)), y: 0),
                                     from: try Self.row(sidebar, Self.plainID)).x
        #expect(abs(memberText - plainText) < 0.5, "a depth-1 member is not indented: member \(memberText), ungrouped \(plainText)")
        #expect(abs(memberText - nameText) <= 1, "member text \(memberText) pt, header name \(nameText) pt")
    }

    @Test func theHoverCloseSitsAtTheEndOfTheTitlesLine() throws {
        let sidebar = Self.sidebar()
        let row = try Self.row(sidebar, Self.plainID)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let close: NSView = row.closeButton
        #expect(!close.isHidden, "the close shows on hover")
        #expect(close is SidebarIconButton, "the close is the row's own x button, not \(type(of: close))")
        let size = SidebarStyle.controlSize
        #expect(close.frame.width == size && close.frame.height == size, "close \(close.frame.size)")
        #expect(abs(close.frame.midY - row.title.frame.midY) < 1, "close centered on the title's line: \(close.frame.midY) vs \(row.title.frame.midY)")
        #expect(close.frame.maxX <= row.bounds.width - SidebarStyle.horizontalInset + 0.5,
                "close ends \(row.bounds.width - close.frame.maxX) pt in, inside the row's inset")
    }
}
