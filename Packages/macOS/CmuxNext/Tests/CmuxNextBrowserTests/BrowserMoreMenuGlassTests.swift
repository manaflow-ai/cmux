import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The browser More (⋮) menu opens on cmux's glass, not as a native `NSMenu` (Lawrence, 2026-11-20:
/// "let's stop using native macos for that and make it super good"): pressed More while it is open,
/// a second press closes it, and the page has the keys again once it closes.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserMoreMenuGlassTests {
    /// A page view that takes the keys, as a web view does.
    private final class PageView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Fixture {
        let buttons = BrowserToolbarButtonsView()
        let page = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let window: NSWindow
        let menu = NSMenu()

        init() {
            let host = NSView(), buttons = buttons, page = page
            host.addSubview(page)
            host.addSubview(buttons)
            window = ToolbarButtonsStateTests.window(host)
            buttons.frame.origin = NSPoint(x: 500, y: 40)
            buttons.setFrameSize(buttons.fittingSize)
            buttons.layoutSubtreeIfNeeded()
            window.makeFirstResponder(page)
            menu.addItem(withTitle: "Find…", action: nil, keyEquivalent: "")
        }

        var more: ChromeIconButton? { buttons.button(.overflow) as? ChromeIconButton }
    }

    private static func turnRunLoop() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    @Test func moreOpensOnGlassNotAsANativeMenu() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        var native = false
        var anchor: NSView?
        fixture.buttons.popUpMenu = { _, _, _ in native = true }
        fixture.buttons.showGlassMenu = { _, view in
            anchor = view
            return true
        }
        fixture.buttons.presentGlass(fixture.menu, from: .overflow)
        Self.turnRunLoop()
        #expect(!native, "the More menu popped up as a native NSMenu")
        #expect(anchor === fixture.more, "the glass menu opens from the More button")
        let glass = try #require(fixture.buttons.openGlassMenu)
        #expect(glass.menu === fixture.menu)
        #expect(fixture.more?.isMenuOpen == true, "More is not pressed while its menu is open")
        glass.close()
        Self.turnRunLoop()
        #expect(fixture.more?.isMenuOpen == false)
        #expect(fixture.buttons.openGlassMenu == nil)
    }

    /// Escape, a click outside or a pick: the page the person was in has the keys again.
    @Test func closingTheMenuGivesTheKeysBackToThePage() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.buttons.showGlassMenu = { _, _ in true }
        fixture.buttons.openGlass(fixture.menu, from: .overflow)
        let glass = try #require(fixture.buttons.openGlassMenu)
        // The press on More (or the menu taking the keys) moved the window's first responder.
        fixture.window.makeFirstResponder(nil)
        glass.list.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        Self.turnRunLoop()
        #expect(fixture.window.firstResponder === fixture.page, "the page did not get the keys back after Escape")
    }

    @Test(.enabled("a glass menu needs a screen to show") { !NSScreen.screens.isEmpty })
    func theMenuOpensUnderMoreWithTrailingEdgesLinedUpAndASecondPressClosesIt() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.window.orderFront(nil)
        fixture.buttons.openGlass(fixture.menu, from: .overflow)
        let glass = try #require(fixture.buttons.shownGlassMenu)
        defer {
            glass.close()
            glass.host.panel.close()
        }
        let more = try #require(fixture.more)
        let button = fixture.window.convertToScreen(more.convert(more.bounds, to: nil))
        let card = glass.host.cardFrame
        #expect(card.maxY <= button.minY, "the menu is not under More")
        #expect(abs(card.maxX - button.maxX) <= 1, "the menu's trailing edge is not More's")
        fixture.buttons.openGlass(fixture.menu, from: .overflow)
        #expect(!glass.isShown, "a second press on More left its menu open")
    }
}
