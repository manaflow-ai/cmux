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

    @Test func itemRowStepsFromHoverToPressedAndBack() {
        let view = row()
        var presses = 0
        view.onPress = { presses += 1 }
        let center = NSPoint(x: 80, y: 14)
        let hover = view.performWithTheme { Palette.hoverFill }, pressed = view.performWithTheme { Palette.pressedFill }
        #expect(view.fill == nil)
        view.mouseEntered(with: event(.mouseEntered, at: center))
        #expect(view.fill == hover)
        view.mouseDown(with: event(.leftMouseDown, at: center))
        #expect(view.fill == pressed)
        #expect(presses == 0, "an item acts on release, so a press that becomes a drag never opens it")
        view.mouseUp(with: event(.leftMouseUp, at: center))
        #expect(view.fill == hover)
        #expect(presses == 1)
        view.mouseDown(with: event(.leftMouseDown, at: center))
        view.mouseExited(with: event(.mouseExited, at: center))
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

    /// SIDEBAR-SELECTION-ONE-MODEL: an active list item draws no fill of its
    /// own (the sidebar's one highlight sits under it); a resting tile keeps
    /// its raised fill.
    @Test func activeItemLeavesItsSelectionToTheHighlightAndTilesRest() {
        let active = row(active: true), tile = row(style: .tile)
        #expect(active.fill == nil)
        #expect(tile.fill == tile.performWithTheme { Palette.hoverFill })
    }

    @Test func iconButtonFillsBehindItsGlyphOnHover() {
        let button = SidebarIconButton(symbol: "plus", label: "New")
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        #expect(button.hover.drawsBehindContent)
        button.mouseEntered(with: event(.mouseEntered, at: NSPoint(x: 12, y: 12)))
        #expect(button.hover.state.hovering)
        button.updateLayer()
        #expect((button.hover.shownFill?.alpha ?? 0) > 0)
        button.mouseExited(with: event(.mouseExited, at: NSPoint(x: 40, y: 40)))
        button.updateLayer()
        #expect(button.hover.state == ChromeHover.State())
        #expect((button.hover.shownFill?.alpha ?? 0) == 0)
    }
}
