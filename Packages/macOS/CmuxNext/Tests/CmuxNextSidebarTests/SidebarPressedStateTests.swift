import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Sidebar items and icon buttons share the chrome hover states: hover,
/// then the pressed step while the pointer is down, cleared on release
/// or exit; an active item keeps its selection fill.
@MainActor @Suite struct SidebarPressedStateTests {
    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func row(active: Bool = false, style: SidebarItemRowView.Style = .builtIn) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        view.configure(SidebarItemInfo(title: "Notifications", symbol: "bell", isActive: active), style: style)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Hosts `view` in a window so the hover owner can read an injected
    /// pointer (`PointerHover`, cx-3wu5).
    private func host(_ view: NSView) -> NSWindow {
        let window = SidebarHoverOwnerTests.window()
        window.contentView.addSubview(view)
        return window
    }

    private func leave(_ window: NSWindow) { PointerHover.setDebugPointer(nil, in: window) }

    @Test func itemRowStepsFromHoverToPressedAndBack() throws {
        let view = row()
        let window = host(view)
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        var presses = 0
        view.onPress = { presses += 1 }
        let center = NSPoint(x: 80, y: 14)
        let hover = view.performWithTheme { Palette.hoverFill }, pressed = view.performWithTheme { Palette.pressedFill }
        #expect(view.fill == nil)
        try SidebarHoverOwnerTests.rest(on: view, at: center)
        #expect(view.fill == hover)
        view.mouseDown(with: event(.leftMouseDown, at: center))
        #expect(view.fill == pressed)
        #expect(presses == 0, "an item acts on release, so a press that becomes a drag never opens it")
        view.mouseUp(with: event(.leftMouseUp, at: center))
        #expect(view.fill == hover)
        #expect(presses == 1)
        view.mouseDown(with: event(.leftMouseDown, at: center))
        leave(window)
        #expect(view.fill == nil, "leaving mid-press clears the pressed fill")
    }

    @Test func aPressThatBecomesADragOrLeavesTheItemNeverActs() {
        let view = row(style: .favorite)
        var presses = 0, drags = 0, ends = 0
        view.onPress = { presses += 1 }
        view.onDragged = { _, _ in drags += 1; return true }
        view.onDragEnded = { ends += 1 }
        let center = NSPoint(x: 80, y: 14)
        view.mouseDown(with: event(.leftMouseDown, at: center))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 120, y: 14)))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 120, y: 14)))
        #expect(drags == 1 && ends == 1)
        #expect(presses == 0, "a drag moves the item; it does not open it")

        view.mouseDown(with: event(.leftMouseDown, at: center))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 400, y: 14)))
        #expect(presses == 0, "released outside the item: no action")
    }

    /// SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION: an active list item paints the
    /// selection fill itself, in place (no shared pill travels under it); a
    /// resting tile keeps its raised fill.
    @Test func activeItemPaintsItsOwnSelectionAndTilesRest() {
        let active = row(active: true), tile = row(style: .tile)
        #expect(active.fill == active.performWithTheme { Palette.selectionFill })
        #expect(tile.fill == tile.performWithTheme { Palette.hoverFill })
    }

    @Test func iconButtonFillsBehindItsGlyphOnHover() throws {
        let button = SidebarIconButton(symbol: "plus", label: "New")
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let window = host(button)
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        #expect(button.hover.drawsBehindContent)
        try SidebarHoverOwnerTests.rest(on: button, at: NSPoint(x: 12, y: 12))
        #expect(button.hover.state.hovering)
        button.updateLayer()
        #expect((button.hover.shownFill?.alpha ?? 0) > 0)
        leave(window)
        button.updateLayer()
        #expect(button.hover.state == ChromeHover.State())
        #expect((button.hover.shownFill?.alpha ?? 0) == 0)
    }
}
