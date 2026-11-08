import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Toolbar buttons return to normal when their menu closes, the media button is not lit while a
/// tab plays, and a pin change reaches the row in a frame, as in Chrome (u2426: "after clicking the Extensions button
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

    /// The page laid out More and the Extensions button where it drew them (its `layout` report).
    static func layOut(_ chrome: BrowserChromeView) {
        let rects: [String: [NSNumber]] = ["button:overflow": [900, 4, 28, 28], "extensions": [860, 4, 28, 28]]
        chrome.addressBar.handle(.layout(BrowserToolbarLayoutReport(wire: ["rects": rects])))
    }

    static func pressed(_ id: String, in buttons: BrowserToolbarButtons) -> Bool? {
        buttons.wire.first { $0["id"] as? String == id }?["pressed"] as? Bool
    }

    /// A toolbar button draws pressed while its menu is open and normal when it closes. An `NSMenu`
    /// tracks the mouse itself, so the page sees no pointer exit: the host's pushed `pressed` flag
    /// is what ends the look (the page's hover is CSS and ends on the next pointer move).
    @Test func aToolbarButtonReturnsToNormalWhenItsMenuCloses() throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        Self.layOut(chrome)
        let buttons = chrome.toolbarButtons
        var shown = false
        buttons.popUpMenu = { _, _, _ in
            shown = true
            #expect(Self.pressed("overflow", in: buttons) == true, "More is not pressed while its menu is open")
        }
        buttons.present(NSMenu(), from: .overflow)
        CFRunLoopRunInMode(.defaultMode, 0, true)
        try #require(shown)
        #expect(Self.pressed("overflow", in: buttons) == false, "More stayed pressed after its menu closed")
    }

    /// Chrome's media button has no "on" look while a tab plays; it is pressed only while its
    /// dialog is open.
    @Test func theMediaButtonIsNotLitWhileATabPlays() {
        var facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: true)
        facts.media = BrowserToolbarMedia(sessions: 1, isPlaying: true)
        #expect(BrowserToolbarPolicy.state(.media, facts).isActive == false)
    }

    /// Unpinning takes the icon out of the pushed row (the page fades it out and slides the
    /// neighbours over under its own motion gate, `data-cmux-motion`).
    @Test func unpinningTakesTheButtonOutOfTheRow() async throws {
        let tab = Self.chromiumTab([Self.action("a", pinned: true), Self.action("b", pinned: true)])
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer { window.close() }
        defer { chrome.closePopupPanels() }
        await Self.settle()
        #expect(Self.pinnedIDs(chrome) == ["a", "b"])
        tab.extensionActions = [Self.action("a", pinned: true), Self.action("b", pinned: false)]
        await Self.settle()
        #expect(chrome.extensionActions.visibleIDs == ["a"])
        #expect(Self.pinnedIDs(chrome) == ["a"])
    }

    static func pinnedIDs(_ chrome: BrowserChromeView) -> [String] {
        (chrome.extensionActions.wire["pinned"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
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
        Self.layOut(chrome)
        let toolbar = chrome.extensionActions
        toolbar.showMenu()
        try #require(toolbar.isMenuShown, "\(ExtensionsMenuPerformanceTests.environment(window))")
        #expect(toolbar.wire["extensionsPressed"] as? Bool == true, "the Extensions button is not pressed while the bubble is open")
        switch path {
        case "close": toolbar.menuController.close()
        case "toggle": toolbar.showMenu()
        case "manage": _ = toolbar.menuController.choose("manage", extension: nil)
        default: toolbar.menuController.dismiss()
        }
        #expect(!toolbar.isMenuShown)
        #expect(toolbar.wire["extensionsPressed"] as? Bool == false, "the Extensions button stayed pressed after \(path)")
    }

    /// A pin toggle reaches the pushed row within a frame (main thread, 16 ms).
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
