import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19 (u2250): "The context menu should open next to the three dots when I
/// click it. So if the workspace sidebar is wider then it is handled better." The group
/// header's more button opened the group editor under the header's full-width color bar, so
/// the bubble sat at the sidebar's leading edge, far from the button in a wide sidebar. A
/// popup opened from a button opens under that button, on its trailing edge, at any width.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarMenuAnchorTests {
    nonisolated static let widths: [CGFloat] = [200, 400, 700]

    /// A sidebar `width` wide in a window that is never ordered front (the bubble is laid out,
    /// not shown), with one group.
    static func sidebar(width: CGFloat, menu: ((SidebarContextTarget) -> NSMenu?)? = nil) throws -> (SidebarView, GroupID, NSWindow) {
        let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red])
        // Rows take their more button's action when they are wired: the provider comes first.
        if let menu { sidebar.contextMenuProvider = menu }
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

    /// Closes the window and the editor bubble the sidebar opened in it. `hide()` only fades the
    /// bubble out and orders it out (it is kept for the next open), so the test closes it.
    static func close(_ sidebar: SidebarView, _ window: NSWindow) {
        sidebar.list.groupEditor.hide()
        sidebar.list.groupEditor.bubble?.close()
        window.close()
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
        defer { Self.close(sidebar, window) }
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

    /// Sidebar sweep 2026-10-21: in a window wider than a narrow sidebar, the editor under the
    /// more button hung about 80 pt past the window's leading edge (the card is wider than the
    /// sidebar, and it lined its trailing edge up with the button). The card stays inside the
    /// window: on the button's leading edge when its trailing edge leaves no room.
    @Test func theGroupEditorStaysInsideTheWindow() throws {
        let width: CGFloat = 200
        let (sidebar, id, window) = try Self.sidebar(width: width)
        defer { Self.close(sidebar, window) }
        window.setContentSize(NSSize(width: 900, height: 600))
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        let more = header.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the more button has no action")

        let content = window.convertToScreen(window.contentLayoutRect)
        let button = try Self.screenRect(of: more.frame, in: header)
        let card = try Self.card(sidebar)
        #expect(content.contains(card), "width \(width): card \(card) leaves the window's content \(content)")
        #expect(abs(card.minX - button.minX) <= 1, "width \(width): card \(card) is not on the button \(button)'s leading edge")
        #expect(card.maxY <= button.minY + 0.5 && button.minY - card.maxY <= 12)
    }

    /// A click on the group's name still opens the editor under the name, on its leading edge.
    @Test(arguments: widths)
    func theNameOpensTheGroupEditorUnderTheName(width: CGFloat) throws {
        let (sidebar, id, window) = try Self.sidebar(width: width)
        defer { Self.close(sidebar, window) }
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        sidebar.list.groupEditing.open(id)
        let name = try Self.screenRect(of: header.nameHitFrame, in: header)
        let card = try Self.card(sidebar)
        #expect(abs(card.minX - name.minX) <= 1, "width \(width): card \(card) is not on the name \(name)'s leading edge")
        #expect(card.maxY <= name.minY + 0.5 && name.minY - card.maxY <= 12)
    }

    /// The menu `present` opened: its frame in `view` (flipped, y down), from the anchor's origin.
    static func menuFrame(_ menu: NSMenu, _ anchor: PopupAnchor, _ view: NSView) -> CGRect {
        let origin = anchor.menuOrigin(size: menu.size, flipped: view.isFlipped)
        return CGRect(origin: origin, size: menu.size)
    }

    static func wideMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Move Workspace to a New Window Somewhere Else", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Close", action: nil, keyEquivalent: "")
        return menu
    }

    /// A workspace row's more button opens the row's menu under the button, on its trailing edge.
    @Test(arguments: widths)
    func aWorkspaceRowMoreButtonOpensItsMenuUnderTheButton(width: CGFloat) throws {
        let (sidebar, _, window) = try Self.sidebar(width: width, menu: { _ in Self.wideMenu() })
        defer { Self.close(sidebar, window) }
        var shown: (NSMenu, PopupAnchor, NSView)?
        sidebar.list.menuPresenter = { shown = ($0, $1, $2) }
        let row = try #require(sidebar.list.rowViews.values.compactMap { $0 as? WorkspaceRowView }.first, "no workspace row")
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let more = row.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the row's more button has no action")
        let (menu, anchor, view) = try #require(shown, "the more button opened no menu")
        #expect(view === row)
        let frame = Self.menuFrame(menu, anchor, view)
        let button = more.frame
        #expect(abs(frame.maxX - button.maxX) <= 1, "width \(width): menu \(frame) is not on the button \(button)'s trailing edge")
        #expect(frame.minY >= button.maxY && frame.minY - button.maxY <= 8, "width \(width): menu \(frame) is not just under \(button)")
    }

    /// The editor's More Group Actions row opens the group's full menu under the header's more button.
    @Test(arguments: widths)
    func moreGroupActionsOpensTheMenuUnderTheMoreButton(width: CGFloat) throws {
        let (sidebar, id, window) = try Self.sidebar(width: width)
        defer { Self.close(sidebar, window) }
        sidebar.contextMenuProvider = { _ in Self.wideMenu() }
        var shown: (NSMenu, PopupAnchor, NSView)?
        sidebar.list.menuPresenter = { shown = ($0, $1, $2) }
        sidebar.list.groupEditing.showMenu(id)
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        let (menu, anchor, view) = try #require(shown, "More Group Actions opened no menu")
        #expect(view === header)
        let frame = Self.menuFrame(menu, anchor, view)
        let button = header.moreButton.frame
        #expect(abs(frame.maxX - button.maxX) <= 1, "width \(width): menu \(frame) is not on the button \(button)'s trailing edge")
        #expect(frame.minY >= button.maxY && frame.minY - button.maxY <= 8)
    }

    /// The editor opened at a point opens there, not at a button. (A right-click on the header
    /// now shows the group's flat menu, Lawrence 2026-10-20; the pointer opener stays for callers.)
    @Test func aRightClickOpensTheGroupEditorAtThePointer() throws {
        let (sidebar, id, window) = try Self.sidebar(width: 700)
        defer { Self.close(sidebar, window) }
        let list = sidebar.list
        let row = try #require(list.displayed.row(for: .group(id)))
        // Room for the card on the pointer's trailing side: past the window's edge it slides back
        // inside (theGroupEditorStaysInsideTheWindow), which only a host with no screen skipped.
        let point = NSPoint(x: 300, y: list.frame(for: row).midY)
        list.groupEditing.open(id, from: .pointer(point))
        let pointer = try #require(list.window).convertPoint(toScreen: list.convert(point, to: nil))
        let card = try Self.card(sidebar)
        #expect(abs(card.minX - pointer.x) <= 1 && abs(card.maxY - pointer.y) <= 1, "card \(card) is not at the pointer \(pointer)")
    }
}
