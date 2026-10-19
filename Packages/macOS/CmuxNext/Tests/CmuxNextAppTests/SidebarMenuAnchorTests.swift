import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-19 (u2250): "The context menu should open next to the three dots when I
/// click it. So if the workspace sidebar is wider then it is handled better." The group
/// header's more button opened the group editor under the header's full-width color bar, so
/// the bubble sat at the sidebar's leading edge, far from the button in a wide sidebar. A
/// popup opened from a button opens under that button, on its trailing edge, at any width.
@MainActor @Suite(.serialized) struct SidebarMenuAnchorTests {
    nonisolated static let widths: [CGFloat] = [200, 400, 700]

    /// A sidebar `width` wide in a window that is never ordered front (the bubble is laid out,
    /// not shown), with one group.
    static func sidebar(width: CGFloat) throws -> (SidebarView, GroupID, NSWindow) {
        let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: width, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        window.contentView?.addSubview(sidebar)
        sidebar.list.groupEditor.ordersFront = false
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, ids[0], window)
    }

    static func screenRect(of rect: NSRect, in view: NSView) throws -> CGRect {
        let window = try #require(view.window)
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    /// The editor's card on screen (the bubble window keeps a shadow band around it).
    static func card(_ sidebar: SidebarView) throws -> CGRect {
        let bubble = try #require(sidebar.list.groupEditor.bubble, "no editor bubble")
        return PopupStyle.standard.cardFrame(inWindow: bubble.frame)
    }

    @Test(arguments: widths)
    func theMoreButtonOpensTheGroupEditorUnderTheButton(width: CGFloat) throws {
        let (sidebar, id, window) = try Self.sidebar(width: width)
        defer { sidebar.list.groupEditor.hide(); window.close() }
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        let more = header.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the more button has no action")
        #expect(sidebar.list.groupEditor.shownGroup == id)

        let button = try Self.screenRect(of: more.frame, in: header)
        let card = try Self.card(sidebar)
        // Trailing-aligned with the button, and just under it.
        #expect(abs(card.maxX - button.maxX) <= 1, "width \(width): card \(card) is not on the button \(button)'s trailing edge")
        #expect(card.maxY <= button.minY + 0.5 && button.minY - card.maxY <= 12,
                "width \(width): card \(card) is not just under the button \(button)")
    }

    /// A click on the group's name still opens the editor under the name, on its leading edge.
    @Test(arguments: widths)
    func theNameOpensTheGroupEditorUnderTheName(width: CGFloat) throws {
        let (sidebar, id, window) = try Self.sidebar(width: width)
        defer { sidebar.list.groupEditor.hide(); window.close() }
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        sidebar.list.groupEditing.open(id)
        let name = try Self.screenRect(of: header.nameHitFrame, in: header)
        let card = try Self.card(sidebar)
        #expect(abs(card.minX - name.minX) <= 1, "width \(width): card \(card) is not on the name \(name)'s leading edge")
        #expect(card.maxY <= name.minY + 0.5 && name.minY - card.maxY <= 12)
    }
}
