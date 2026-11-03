import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Toolbar buttons return to normal when their menu closes, the media button is not lit while a
/// tab plays, and pinning animates, as in Chrome (u2426: "after clicking the Extensions button
/// and the Music/audio button, both stay highlighted/active forever"). Prints the timings.
@MainActor @Suite(.serialized, .closesItsWindows) struct ToolbarButtonsStateTests {
    static func window(_ view: NSView, width: CGFloat = 1000) -> NSWindow {
        // Inside the main screen, with room below for a menu (CI workers run small virtual displays).
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let frame = NSRect(x: screen.minX + 10, y: screen.maxY - 160, width: min(width, screen.width - 20), height: 120)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = window.contentLayoutRect
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        return window
    }

    /// Lets the observation loops (one main-actor task each) render.
    static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    static func chromiumTab(_ actions: [CEFExtensionAction]) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        tab.extensionActions = actions
        return tab
    }

    static func action(_ id: String, pinned: Bool) -> CEFExtensionAction {
        CEFExtensionAction(id: id, name: "Extension \(id)", title: id, isPinned: pinned)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The pointer leaves the button while its menu is open. An `NSMenu` tracks the mouse itself,
    /// so the button gets no exit event: the hover must be read again when the menu closes.
    @Test func aToolbarButtonReturnsToNormalWhenItsMenuCloses() throws {
        let buttons = BrowserToolbarButtonsView()
        let host = NSView()
        host.addSubview(buttons)
        let window = Self.window(host)
        defer { window.close() }
        buttons.frame.origin = NSPoint(x: 20, y: 40)
        buttons.setFrameSize(buttons.fittingSize)
        buttons.layoutSubtreeIfNeeded()
        let more = try #require(buttons.button(.overflow) as? ChromeIconButton)
        PointerHover.setDebugPointer(more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil), in: window)
        try #require(more.isHovering)
        var shown = false
        buttons.popUpMenu = { _, _, _ in
            shown = true
            #expect(more.isMenuOpen, "More is not pressed while its menu is open")
            PointerHover.debugPointers[ObjectIdentifier(window)] = .init(point: NSPoint(x: 900, y: 10), mouse: NSEvent.mouseLocation)
        }
        buttons.present(NSMenu(), from: .overflow)
        CFRunLoopRunInMode(.defaultMode, 0, true)
        try #require(shown)
        #expect(!more.isHovering, "More stayed lit after its menu closed")
        #expect(!more.isMenuOpen)
        PointerHover.setDebugPointer(nil, in: window)
    }

    /// Chrome's media button has no "on" look while a tab plays; it is pressed only while its
    /// dialog is open.
    @Test func theMediaButtonIsNotLitWhileATabPlays() {
        var facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: true)
        facts.media = BrowserToolbarMedia(sessions: 1, isPlaying: true)
        #expect(BrowserToolbarPolicy.state(.media, facts).isActive == false)
    }

    /// Unpinning fades the icon out and the neighbours slide over (about 0.2 s), so the button
    /// stays in the toolbar until the fade ends.
    @Test func unpinningFadesTheButtonOutBeforeItLeaves() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tab = Self.chromiumTab([Self.action("a", pinned: true), Self.action("b", pinned: true)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        let leaving = try #require(chrome.extensionToolbar.button(for: "b"))
        tab.extensionActions = [Self.action("a", pinned: true), Self.action("b", pinned: false)]
        await Self.settle()
        #expect(chrome.extensionToolbar.visibleIDs == ["a"])
        #expect(chrome.extensionToolbar.lastPinAnimation?.left == ["b"], "the unpinned icon left with no fade")
        #expect(leaving.superview !== chrome.extensionSlot)
    }

    /// The Extensions button is pressed while its bubble is open and normal after every way
    /// the bubble closes: Escape, the close button, a second click, a pick, a click outside.
    @Test(.enabled("a bubble needs a screen to show") { await ExtensionsMenuPerformanceTests.hasDisplay() },
          arguments: ["close", "toggle", "manage", "dismiss"])
    func theExtensionsButtonIsPressedOnlyWhileItsBubbleIsOpen(_ path: String) async throws {
        let tab = Self.chromiumTab([Self.action("a", pinned: false)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        let toolbar = chrome.extensionToolbar
        toolbar.showMenu()
        try #require(toolbar.isMenuShown, "\(ExtensionsMenuPerformanceTests.environment(window))")
        #expect(toolbar.puzzle.isMenuOpen, "the Extensions button is not pressed while the bubble is open")
        switch path {
        case "close": toolbar.menuController.close()
        case "toggle": toolbar.showMenu()
        case "manage": _ = toolbar.menuController.choose("manage", extension: nil)
        default: toolbar.menuController.dismiss()
        }
        #expect(!toolbar.isMenuShown)
        #expect(!toolbar.puzzle.isMenuOpen, "the Extensions button stayed pressed after \(path)")
    }

    /// Pinning fades the new icon in while the neighbours slide.
    @Test func pinningFadesTheNewIconIn() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tab = Self.chromiumTab([Self.action("a", pinned: true), Self.action("b", pinned: false)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        #expect(chrome.extensionToolbar.lastPinAnimation == nil, "a tab's first icons appeared with an animation")
        tab.extensionActions = [Self.action("a", pinned: true), Self.action("b", pinned: true)]
        await Self.settle()
        #expect(chrome.extensionToolbar.visibleIDs == ["a", "b"])
        #expect(chrome.extensionToolbar.lastPinAnimation?.arrived == ["b"])
    }

    @Test func underReduceMotionUnpinningIsInstant() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let tab = Self.chromiumTab([Self.action("a", pinned: true), Self.action("b", pinned: true)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        let leaving = try #require(chrome.extensionToolbar.button(for: "b"))
        tab.extensionActions = [Self.action("a", pinned: true), Self.action("b", pinned: false)]
        await Self.settle()
        #expect(leaving.superview == nil)
        #expect(chrome.extensionToolbar.lastPinAnimation == nil)
    }

    /// A pin toggle re-renders the toolbar within a frame (main thread, 16 ms).
    @Test func aPinToggleRendersWithinAFrame() async throws {
        let pinned = (0..<6).map { Self.action("e\($0)", pinned: true) }
        let tab = Self.chromiumTab(pinned + [Self.action("x", pinned: false)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        let clock = ContinuousClock()
        var toggles: [Duration] = []
        for pin in [true, false, true, false, true, false, true, false] {
            toggles.append(await clock.measure {
                tab.extensionActions = pinned + [Self.action("x", pinned: pin)]
                await Self.settle()
                chrome.layoutSubtreeIfNeeded()
            })
        }
        // The median: a loaded CI worker stalls some runs; the code's own cost is the typical run.
        let median = toggles.sorted()[toggles.count / 2]
        print("TOOLBAR-PERF pin.toggle.median=\(Self.milliseconds(median)) ms pin.toggle.max=\(Self.milliseconds(toggles.max() ?? .zero)) ms")
        #expect(Self.milliseconds(median) < 16, "a pin toggle took \(Self.milliseconds(median)) ms")
    }

    static func cards(_ count: Int) -> [BrowserMediaRows.Card] {
        (0..<count).map { index in
            BrowserMediaRows.Card(key: "tab\(index)", title: "Track \(index)", subtitle: "Artist · example.com",
                                  media: BrowserMediaState(title: "Track \(index)", isPlaying: index == 0, position: 30, duration: 240),
                                  artwork: nil, onCommand: { _ in }, onReveal: {})
        }
    }

    /// The media menu with five tabs opens within a frame: the cards are kept between opens.
    @Test func theMediaMenuOpensWithinAFrame() {
        let rows = BrowserMediaRows()
        let clock = ContinuousClock()
        let first = clock.measure { _ = rows.menu(Self.cards(5), empty: "").size }
        #expect(rows.built == 5)
        let open = ExtensionsMenuPerformanceTests.fastest { _ = rows.menu(Self.cards(5), empty: "").size }
        #expect(rows.built == 5, "a reopen built its cards again")
        print("TOOLBAR-PERF media.menu.first=\(Self.milliseconds(first)) ms media.menu.open=\(Self.milliseconds(open)) ms")
        #expect(Self.milliseconds(open) < 16, "the media menu took \(Self.milliseconds(open)) ms")
    }

}
