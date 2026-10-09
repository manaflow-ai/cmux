import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-3wu5: sidebar hover is a function of where the pointer is now and
/// where the views are now. A reflow, a resize, a hide or a collapse moves
/// views under a still pointer and sends no exit; the hover must follow.
/// The pointer is injected (`PointerHover.setDebugPointer`): tests never
/// read the real mouse.
@MainActor @Suite(.serialized)
struct SidebarHoverOwnerTests {
    static func window(width: CGFloat = 260, height: CGFloat = 600) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The pointer rests at `point` (in `view`'s coordinates) and the enter
    /// reaches whoever owns `view`'s tracking areas, as AppKit delivers it.
    static func rest(on view: NSView, at point: NSPoint) throws {
        let window = try #require(view.window)
        let windowPoint = view.convert(point, to: nil)
        PointerHover.setDebugPointer(windowPoint, in: window)
        view.updateTrackingAreas()
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        for area in view.trackingAreas {
            if let hover = area.owner as? PointerHover { hover.mouseEntered(with: event) } else if let owner = area.owner as? NSResponder {
                owner.mouseEntered(with: event)
            }
        }
    }

    static func center(_ view: NSView) -> NSPoint { NSPoint(x: view.bounds.midX, y: view.bounds.midY) }

    /// ChromeHover (the sidebar's + button) and the sidebar's chrome reveal:
    /// the sidebar narrows under a still pointer (a window or column resize),
    /// the button moves left and the pointer ends outside the sidebar.
    @Test func narrowingTheSidebarUnderAStillPointerClearsTheButtonAndTheReveal() throws {
        let harness = MinimalChromeTests.Harness()
        let window = harness.window, sidebar = harness.sidebar
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        let button = sidebar.newButton
        try Self.rest(on: sidebar, at: sidebar.convert(Self.center(button), from: button))
        try Self.rest(on: button, at: Self.center(button))
        #expect(button.hover.state.hovering)
        #expect(sidebar.isChromeRevealed)

        sidebar.setFrameSize(NSSize(width: 160, height: sidebar.frame.height))
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()

        #expect(!button.hover.state.hovering, "the + moved out from under the pointer")
        #expect(!sidebar.isChromeRevealed, "the pointer is outside the sidebar now")
    }

    static func listSection(_ items: [SidebarBuiltIn]) -> LayoutSection {
        LayoutSection(id: LayoutSectionID("top"), region: .top, look: .builtIn,
                      items: items.map { LayoutItem(id: LayoutItemID("itm_\($0.rawValue)"), ref: .builtIn($0)) })
    }

    static func content(_ items: [SidebarBuiltIn]) -> SidebarRegionView.Content {
        SidebarRegionView.Content(sections: [listSection(items)], infos: [:], collapsed: [], look: .quiet,
                                  metrics: .standard, drawsLines: true)
    }

    /// Section items: an item is inserted above the hovered one; the rows
    /// reflow under the still pointer. The row that moved away clears and
    /// the row now under the pointer is the hovered one.
    @Test func aReflowMovesTheItemHoverToTheRowUnderThePointer() throws {
        let window = Self.window()
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        let region = SidebarRegionView(region: .top)
        region.update(Self.content([.home, .settings]), width: 240)
        region.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        window.contentView.addSubview(region)
        let home = try #require(region.itemView(LayoutItemID("itm_home")))
        let point = region.convert(Self.center(home), from: home)
        try Self.rest(on: home, at: Self.center(home))
        #expect(home.isHovered)

        region.update(Self.content([.notifications, .home, .settings]), width: 240)

        let notifications = try #require(region.itemView(LayoutItemID("itm_notifications")))
        #expect(!home.frame.contains(point), "the row moved down")
        #expect(notifications.frame.contains(point))
        #expect(!home.isHovered, "the row that moved away is not hovered")
        #expect(notifications.isHovered, "the row now under the pointer is")
    }

    /// The resize handle's edge line: the sidebar hides (the handle hides with
    /// it) while the pointer rests on the edge.
    @Test func hidingTheResizeHandleUnderAStillPointerClearsItsLine() throws {
        let window = Self.window()
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        let handle = SidebarResizeHandle(frame: NSRect(x: 100, y: 0, width: 8, height: 400))
        window.contentView.addSubview(handle)
        try Self.rest(on: handle, at: Self.center(handle))
        #expect(handle.isHovered)

        handle.isHidden = true

        #expect(!handle.isHovered)
        #expect(!handle.isLineVisible)
    }

    static func card(_ id: String) -> SidebarCard {
        SidebarCard(id: id, title: "Card \(id)", dismissible: true, alwaysVisible: false)
    }

    /// Cards: hover expands the stack; the sidebar's chrome hides (the
    /// announcement cards go with it) while the pointer rests where the
    /// cards were. The stack collapses: nothing it shows is under the pointer.
    @Test func hidingTheCardsUnderAStillPointerCollapsesTheStack() throws {
        let window = Self.window()
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        let stack = SidebarCardStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView.addSubview(stack)
        stack.revealed = true
        stack.show([Self.card("a"), Self.card("b")])
        stack.layoutSubtreeIfNeeded()
        let front = try #require(stack.subviews.compactMap { $0 as? SidebarCardView }.first { $0.card.id == "a" })
        try Self.rest(on: stack, at: stack.convert(Self.center(front), from: front))
        #expect(stack.isExpanded)

        stack.revealed = false
        stack.layoutSubtreeIfNeeded()

        #expect(!stack.isExpanded, "no card is under the pointer any more")
    }
}
