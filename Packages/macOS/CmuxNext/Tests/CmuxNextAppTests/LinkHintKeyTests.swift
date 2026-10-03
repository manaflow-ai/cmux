import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Link hints are bare keys (`f`, `F`): they run only after a Chromium page
/// passed the letter on outside any text field, never from the window's
/// key path, where a page field (WebKit's included) or a terminal wants it.
@MainActor
struct LinkHintKeyTests {
    typealias K = KeyInterceptionTests

    @Test func bareLinkHintKeysNeverRunFromTheWindowKeyPath() throws {
        let services = ActionBindingCoverageTests.boundServices()
        var ran: [ActionID] = []
        for id: ActionID in ["browserLinkHints", "browserLinkHintsNewSplit"] {
            services.registry.bind(id, invoke: { _ in ran.append(id) })
        }
        services.registry.context.insert(.browserFocused)
        #expect(services.registry.resolve(Shortcut("f", modifiers: []))?.id == "browserLinkHints")
        #expect(services.registry.resolve(Shortcut("f", modifiers: [.shift]))?.id == "browserLinkHintsNewSplit")
        let follow = try K.key("f", keyCode: 3, [])
        let split = try K.key("F", keyCode: 3, [.shift])
        for event in [follow, split] {
            #expect(services.keyRouter.isPageKey(event, id: "browserLinkHints"))
            for focus in [K.page, K.omnibar, K.terminal] {
                #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: focus))
            }
        }
        #expect(ran.isEmpty)
        // A chord bound to the same action is an ordinary shortcut.
        let chord = try K.key("f", keyCode: 3, [.command, .option])
        #expect(!services.keyRouter.isPageKey(chord, id: "browserLinkHints"))
    }

    @Test func linkHintKeysNeedBrowserFocus() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context.insert(.terminalFocused)
        #expect(services.registry.resolve(Shortcut("f", modifiers: []))?.id != "browserLinkHints")
        #expect(services.registry.resolve(Shortcut("f", modifiers: [.shift]))?.id != "browserLinkHintsNewSplit")
        #expect(!services.linkHints.isActive)
    }

    private static func tab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Labels show, then a click moves the keyboard to a terminal or a field
    /// in the same window: the next letter is typing, not a hint.
    @Test func aSessionEndsOnceThePageLosesTheKeyboard() throws {
        let hints = LinkHintController()
        let tab = Self.tab()
        let window = Self.window()
        var focused = true
        hints.start(.follow, tab: tab, window: window, isFocused: { focused }, openInSplit: { _ in }, notice: { _ in })
        let letter = try K.key("s", keyCode: 1, [])
        #expect(hints.interceptKeyDown(letter, in: window))
        focused = false
        #expect(!hints.interceptKeyDown(letter, in: window))
        #expect(!hints.isActive)
    }

    /// A session without a window (its window closed) never takes keys
    /// from another window.
    @Test func aSessionWithoutAWindowTakesNoKeys() throws {
        let hints = LinkHintController()
        hints.start(.follow, tab: Self.tab(), window: nil, isFocused: { true }, openInSplit: { _ in }, notice: { _ in })
        #expect(!hints.interceptKeyDown(try K.key("s", keyCode: 1, []), in: Self.window()))
        #expect(!hints.isActive)
    }
}
