import AppKit
@testable import CmuxNextApp
import CmuxNextPages
@testable import CmuxNextPhone
import CmuxNextWakeups
import Testing

/// A page a window shows as its top page (the Phone page in a window with no pane) follows the
/// node its key has in `TabContentCache.node(for:)`, as a pane's tab does. The top page host holds that node under the
/// window's node and sets it visible while the window shows the page, so the phone's screen streams there and its
/// controls follow the service; before, no pane selected the top page's key, so its node stayed hidden for good.
@MainActor @Suite(.serialized)
struct TopPagePhoneVisibilityTests {
    @Test func aPhoneShownAsATopPageIsOnScreenAndHiddenWhenTheWindowLeavesIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let tab = PhonePageTab(phones: InternalPageDiscardPolicyCoverageTestsBatch5.phones(), mainWork: services.mainWork,
                               nodes: { cache.node(for: $0) })
        let key = LocalPageTab.makeKey(.phone)
        let windowNode = VisibilityNode(root: "test.window", own: .visible)
        let host = TopPageHost(make: { _, window in (view: tab.makeView(for: key, in: window), key: key as String?) },
                               closed: { _, closedKey in tab.tabClosed(closedKey) },
                               discardable: { _, _ in nil }, title: { $0.rawValue }, discards: false, hiddenLimit: 8,
                               hosts: { [] }, deadline: NoDiscardDeadline(), windowNode: windowNode, pageNode: { cache.node(for: $0) })
        let route = TopPageRoute.page(.phone)
        let page = try #require(host.view(for: route, in: nil) as? PhoneTabView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(page)
        #expect(!page.screen.isOnScreen, "a top page the window does not show yet is on screen")

        host.contentDidChange(shown: page)
        #expect(cache.node(for: key).isVisible, "the shown top page's node stayed hidden")
        #expect(page.screen.isOnScreen, "the phone shown as a top page is not on screen: its screen never streams")

        host.contentDidChange(shown: nil)
        #expect(!page.screen.isOnScreen, "the phone stayed on screen after the window left its page")

        windowNode.set(.hidden)
        host.contentDidChange(shown: page)
        #expect(!page.screen.isOnScreen, "the page of a hidden window is on screen")
        host.teardown()
        withExtendedLifetime(services) {}
    }
}

/// The discard deadline of a host that never discards.
@MainActor
private final class NoDiscardDeadline: PageDiscardDeadline {
    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {}
    func disarm() {}
}
