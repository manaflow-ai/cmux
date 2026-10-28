import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// A press on a page's own toolbar (Downloads, More, profile, media) names its tab, and the action
/// acts on that page, whatever pane has focus (Lawrence 2026-10-18 on the Home workspace's browser
/// tab: "if you click on anything I see no browser tab is focused"). Before 28fcf001fa6 the target
/// resolved through the focused pane's selected content, so a press on a page that was not that
/// content (another workspace's dock had focus, a pane shown in two windows, an adopted Web Store
/// tab) refused with "No browser tab is focused."
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserToolbarPressTargetTests {
    private func onScreen(_ key: String, in services: AppServices) -> (BrowserEntry, NSWindow) {
        let entry = services.cache.browser(for: key, url: URL(string: "https://example.com/\(key)"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        entry.chrome.frame = window.contentLayoutRect
        window.contentView = entry.chrome
        return (entry, window)
    }

    @Test func aPressNamingAnOnScreenTabActsOnThatPageWithNoFocusedPane() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let context = AppActionContext(services: services)
        let (entry, window) = onScreen("toolbar-press-a", in: services)
        defer { window.close(); services.cache.release("toolbar-press-a") }
        #expect(services.windows.active?.focusedPane == nil, "no workspace pane has focus")
        let target = ActionTargetRef(kind: .tab, id: "toolbar-press-a")
        let page = try context.page(ActionInvocation(target: target))
        #expect(page === entry)
    }

    @Test func eachTabsPressActsOnItsOwnPage() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let context = AppActionContext(services: services)
        let (first, firstWindow) = onScreen("toolbar-press-b", in: services)
        let (second, secondWindow) = onScreen("toolbar-press-c", in: services)
        defer {
            firstWindow.close(); secondWindow.close()
            services.cache.release("toolbar-press-b"); services.cache.release("toolbar-press-c")
        }
        #expect(try context.page(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "toolbar-press-b"))) === first)
        #expect(try context.page(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "toolbar-press-c"))) === second)
    }

    @Test func aTabNotOnScreenStillNeedsAFocusedBrowserPane() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let context = AppActionContext(services: services)
        _ = services.cache.browser(for: "toolbar-press-d", url: URL(string: "https://example.com/d"))
        defer { services.cache.release("toolbar-press-d") }
        #expect(throws: (any Error).self) {
            try context.page(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "toolbar-press-d")))
        }
    }
}
