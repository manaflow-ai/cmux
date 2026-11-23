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

    /// The menu buttons open on the press; Downloads' popup does not follow a held press, so it opens
    /// on the release as before; the toggles never open on the press.
    @Test func menuButtonsOpenOnThePressAndDownloadsOnTheRelease() throws {
        for button in BrowserToolbarButton.allCases {
            let expected = [.media, .profile, .theme, .overflow].contains(button)
            #expect(button.followsPress == expected, "\(button) followsPress")
        }
        let fixture = Fixture()
        defer { fixture.window.close() }
        #expect(try #require(fixture.more).opensOnPress)
    }

    private final class RowTarget: NSObject {
        var ran: [String] = []
        @objc func run(_ sender: NSMenuItem) { ran.append(sender.title) }
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// Press More and hold, drag onto a row, release: the row runs (Leo: "so he click and hold on the
    /// context menu start and then it goes over and then release should go"). The press opens the menu
    /// (not its release), and More hands the press's drag and release to it.
    @Test(.enabled("a glass menu needs a screen to show") { !NSScreen.screens.isEmpty })
    func pressHoldDragOntoARowAndReleaseRunsIt() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.window.orderFront(nil)
        let target = RowTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in ["Find…", "Print…"] {
            menu.addItem(withTitle: title, action: #selector(RowTarget.run(_:)), keyEquivalent: "").target = target
        }
        var presses = 0
        fixture.buttons.onPress = { [buttons = fixture.buttons] button in
            guard button == .overflow else { return }
            presses += 1
            buttons.openGlass(menu, from: .overflow)
        }
        let more = try #require(fixture.more)
        let window = fixture.window
        let onMore = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        more.mouseDown(with: try Self.mouse(.leftMouseDown, at: onMore, in: window))
        #expect(presses == 1, "the press did not open the menu: More waits for its release")
        let glass = try #require(fixture.buttons.shownGlassMenu)
        defer {
            glass.close()
            glass.host.panel.close()
        }
        #expect(more.holdsPress)
        let row = try #require(glass.list.view(at: 1))
        let rowRect = try #require(row.window).convertToScreen(row.convert(row.bounds, to: nil))
        let onRow = window.convertPoint(fromScreen: NSPoint(x: rowRect.midX, y: rowRect.midY))
        more.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: onRow, in: window))
        #expect(glass.isShown)
        more.mouseUp(with: try Self.mouse(.leftMouseUp, at: onRow, in: window))
        #expect(!glass.isShown, "releasing on Print… left the menu open")
        Self.turnRunLoop()
        #expect(target.ran == ["Print…"])
        #expect(!more.holdsPress)
    }

    /// A quick click on More (press and release on it) opens the menu and leaves it open.
    @Test(.enabled("a glass menu needs a screen to show") { !NSScreen.screens.isEmpty })
    func aClickOnMoreLeavesTheMenuOpen() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.window.orderFront(nil)
        fixture.buttons.onPress = { [buttons = fixture.buttons, menu = fixture.menu] button in
            if button == .overflow { buttons.openGlass(menu, from: .overflow) }
        }
        let more = try #require(fixture.more)
        let onMore = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        more.mouseDown(with: try Self.mouse(.leftMouseDown, at: onMore, in: fixture.window))
        more.mouseUp(with: try Self.mouse(.leftMouseUp, at: onMore, in: fixture.window))
        let glass = try #require(fixture.buttons.shownGlassMenu, "a click on More closed its menu")
        glass.close()
        glass.host.panel.close()
    }
}
