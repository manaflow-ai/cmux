import Foundation
import WebKit

/// What a WebKit tab gives its restored session (`BrowserRestoredSession`):
/// session history across relaunch, as Chromium tabs have it.
struct WebKitRestoredSessionHost: BrowserRestoredSessionHost {
    let tab: WebKitTab

    static func session(for tab: WebKitTab) -> BrowserRestoredSession {
        BrowserRestoredSession { [weak tab] in tab.map(WebKitRestoredSessionHost.init) }
    }

    var state: BrowserTabState { tab.state }
    var isClosed: Bool { tab.isClosed }
    var nativeHistory: (back: Bool, forward: Bool) { (tab.webView.canGoBack, tab.webView.canGoForward) }

    func nativeNavigationList() -> BrowserNavigationList? {
        let list = tab.webView.backForwardList
        guard let current = list.currentItem else { return nil }
        let back = list.backList
        let items = back + [current] + list.forwardList
        return BrowserNavigationList(entries: items.map { BrowserNavigationEntry(url: $0.url, title: $0.title) }, current: back.count)
    }

    func goToNativeEntry(offset: Int) -> Bool {
        guard let item = tab.webView.backForwardList.item(at: offset) else { return false }
        tab.webView.go(to: item)
        return true
    }

    func applyHistoryAvailability(canGoBack: Bool, canGoForward: Bool) {
        tab.apply(.historyChanged(canGoBack: canGoBack, canGoForward: canGoForward))
    }

    func currentScrollY() async -> Double? {
        guard case .number(let y)? = try? await tab.evaluate("window.scrollY", world: .isolated, gesture: .cmux) else { return nil }
        return y
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        try await tab.evaluate(script, world: world, gesture: gesture)
    }

    func load(_ url: URL) { tab.load(url) }
}
