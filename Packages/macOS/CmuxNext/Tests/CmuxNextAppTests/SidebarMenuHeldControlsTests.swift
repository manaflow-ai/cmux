import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-26: "If it's a toggle, if it's something like that, then you keep it on when you click the context
/// menu, when you click the top, the drop-down, the popover, whatever the fucking. We say we keep it." A hover-revealed
/// control stays shown and lit while the menu, popover or editor it opened is open, though the pointer leaves for it.
/// Leo 2026-10-27: "why are you giving it the entire row when it's only this small little section? Just don't do that.
/// Don't ever do that." Only that control lights: the row keeps its own fill. One test per row kind.
@MainActor @Suite(.serialized) struct SidebarMenuHeldControlsTests {
    static func paint(_ view: NSView) {
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    /// A workspace row's ⋮ menu (`SidebarRowMenu`): while it tracks, the pointer has left the row for the menu.
    @Test func aWorkspaceRowKeepsItsMoreButtonShownAndLitWhileItsMenuIsOpen() throws {
        let (sidebar, window, _, second, _, _) = try SidebarRowMenuNoFocusTests.sidebar()
        defer { window.close() }
        let row = try #require(sidebar.list.rowViews[.workspace(second)] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        struct Seen { var moreShown = false, moreLit = false, closeShown = false, closeExpected = false, rowFill = true }
        var seen: Seen?
        sidebar.list.menuPresenter = { _, _, _ in
            // The pointer moves onto the menu: the row loses its hover while the menu is open.
            row.isHovered = false
            row.layoutSubtreeIfNeeded()
            Self.paint(row)
            seen = Seen(moreShown: !row.moreButton.isHidden && row.moreButton.alphaValue > 0,
                        moreLit: row.moreButton.hover.state.pressed,
                        closeShown: !row.closeButton.isHidden && row.closeButton.alphaValue > 0,
                        closeExpected: row.isClosable,
                        rowFill: row.debugFill)
        }
        let more = row.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the row's more button has no action")
        let open = try #require(seen, "the row's menu never opened")
        #expect(open.moreShown, "the more button hid while its menu was open")
        #expect(open.moreLit, "the more button was not lit while its menu was open")
        if open.closeExpected { #expect(open.closeShown, "the close x hid while the row's menu was open") }
        #expect(!open.rowFill, "the whole row lit while its menu was open; only the more button may")
        // The menu closed: the button lets go, and with no pointer over the row the controls go.
        row.layoutSubtreeIfNeeded()
        #expect(!row.showsMenu)
        #expect(!row.moreButton.hover.state.pressed, "the more button stayed lit after its menu closed")
        #expect(row.moreButton.isHidden || row.moreButton.alphaValue == 0, "the more button stayed after its menu closed")
    }

    /// A sidebar item row naming a workspace (a pinned tile): its hover ⋮ holds while its menu is open, and the
    /// pill keeps its resting fill (the open menu used to paint the selected fill over the whole row).
    @Test func aWorkspaceItemRowLightsOnlyItsMoreButtonWhileItsMenuIsOpen() throws {
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var info = SidebarItemInfo(title: "Workspace", symbol: "terminal")
        info.workspace = WorkspaceID("ws")
        view.onMore = {}
        view.configure(info, style: .list)
        view.layoutSubtreeIfNeeded()
        #expect(!view.showsHoverActions, "no controls at rest")
        let resting = view.fill
        view.showsMenu = true
        view.layoutSubtreeIfNeeded()
        #expect(view.showsHoverActions, "the open menu does not keep its controls")
        let more = try #require(view.hoverMore, "no more button while its menu is open")
        #expect(!more.isHidden, "the more button hid while its menu was open")
        #expect(more.hover.state.pressed, "the more button was not lit while its menu was open")
        #expect(view.fill == resting, "the whole row lit while its menu was open; only the more button may")
        view.showsMenu = false
        view.layoutSubtreeIfNeeded()
        #expect(!view.showsHoverActions)
        #expect(!more.hover.state.pressed, "the more button stayed lit after its menu closed")
    }

    /// The profile control is its own menu's trigger: the whole pill is the control, so it keeps the selected fill.
    @Test func theProfileControlStillLightsItsPillWhileItsMenuIsOpen() {
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        view.configure(SidebarItemInfo(title: "Profile", symbol: "person"), style: .list)
        let resting = view.fill
        view.showsMenu = true
        #expect(view.fill != resting, "the profile control's pill no longer holds its fill while its menu is open")
    }

    /// A group header's ⋮ opens the group editor (a popover): it stays shown and lit while the editor is open, and
    /// the bar keeps its own fill.
    @Test func aGroupHeaderKeepsItsMoreButtonLitWhileItsEditorIsOpen() throws {
        let (header, window) = try GroupHeaderHoverRevealTests.header()
        defer { window.close() }
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        GroupHeaderHoverRevealTests.hover(header, true)
        header.isEditing = true
        // The pointer leaves the header for the editor.
        GroupHeaderHoverRevealTests.hover(header, false)
        Self.paint(header)
        #expect(!header.moreButton.isHidden && header.moreButton.alphaValue == 1, "the more button hid while the editor was open")
        #expect(header.moreButton.hover.state.pressed, "the more button was not lit while the editor was open")
        #expect(!header.debugFill, "the whole header lit while its editor was open; only the more button may")
        header.isEditing = false
        header.layoutSubtreeIfNeeded()
        #expect(!header.moreButton.hover.state.pressed, "the more button stayed lit after the editor closed")
        #expect(header.moreButton.isHidden, "the more button stayed after the editor closed")
    }
}
