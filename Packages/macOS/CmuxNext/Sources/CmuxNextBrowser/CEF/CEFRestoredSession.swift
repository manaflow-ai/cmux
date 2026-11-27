import Foundation

/// A Chromium tab's back/forward entries saved before a relaunch
/// (`BrowserRestoredSession`, shared with WebKit tabs).
final class CEFRestoredSession: BrowserRestoredSession {
    init(tab: CEFTab) {
        super.init { [weak tab] in tab.map(CEFRestoredSessionHost.init) }
    }
}

/// What a Chromium tab gives its restored session.
struct CEFRestoredSessionHost: BrowserRestoredSessionHost {
    let tab: CEFTab

    var state: BrowserTabState { tab.state }
    var isClosed: Bool { tab.isClosed }
    var nativeHistory: (back: Bool, forward: Bool) { tab.nativeHistory }
    func nativeNavigationList() -> BrowserNavigationList? { tab.nativeNavigationList() }
    func goToNativeEntry(offset: Int) -> Bool { tab.goToNativeEntry(offset: offset) }
    func applyHistoryAvailability(canGoBack: Bool, canGoForward: Bool) {
        tab.machine.apply(.historyChanged(canGoBack: canGoBack, canGoForward: canGoForward))
    }
    func currentScrollY() async -> Double? { await tab.currentScrollY() }
    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        try await tab.evaluate(script, world: world, gesture: gesture)
    }
    func load(_ url: URL) { tab.load(url) }
}
