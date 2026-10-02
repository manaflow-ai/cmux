import AppKit
import CmuxNextActions
@testable import CmuxNextApp
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
}
