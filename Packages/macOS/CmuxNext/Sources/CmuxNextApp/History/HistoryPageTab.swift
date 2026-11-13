import AppKit
import CmuxNextBrowser
import CmuxNextHistory
import CmuxNextIcons
import CmuxNextPages
import Foundation
import Observation

/// The `cmux://history` page in a browser tab (plans/cmux-next/history.md
/// 5.1, react-pages.md 2): the React History page (cmux-page://cmux.history/),
/// no browser engine. Navigating it to a web address asks the host
/// (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class HistoryPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.history, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let contentView: NSView
    /// The React page; nil only when the app's page resources are missing (an empty view shows).
    @ObservationIgnored let webPage: PageWebView?
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, webPage: PageWebView?) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: URL.historyPage, title: HistoryPageStrings.title)
        state.phase = .finished
        self.state = state
        self.webPage = webPage
        contentView = webPage ?? NSView()
    }

    func load(_ url: URL) {
        if url.isHistoryPage { return reload() }
        onNavigate?(url)
    }

    func reload() {
        webPage?.reload()
    }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, contentView.window != nil else { return }
        webPage?.focusPage()
    }

    func setContentVisible(_ visible: Bool) {
        // The page stays current from the owner's change events (`history-changed`).
        contentView.isHidden = !visible
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        webPage?.send(command: "find", arguments: ["text": .string(text)])
        return .none
    }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() { webPage?.close() }
}

enum HistoryPageStrings {
    static var title: String { String(localized: "history.page.tabTitle", defaultValue: "History", table: "History", bundle: .module) }
}
