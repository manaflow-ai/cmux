import AppKit
import CmuxNextBrowser
import CmuxNextHistory
import CmuxNextPages
import Foundation
import Observation

/// The `cmux://history` page in a browser tab (plans/cmux-next/history.md
/// 5.1): a native view, no engine. Navigating it to a web address asks the
/// host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class HistoryPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: HistoryPageModel
    @ObservationIgnored let contentView: NSView
    /// The React page (Debug Settings `history.surface = web`; react-pages.md H1b), else nil.
    @ObservationIgnored let webPage: PageWebView?
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: any HistoryPageSource,
         webPage: PageWebView? = nil) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: HistoryPageAddress.url, title: HistoryPageStrings.title)
        state.phase = .finished
        self.state = state
        model = HistoryPageModel(source: source)
        self.webPage = webPage
        if let webPage {
            contentView = webPage
        } else {
            contentView = HistoryPageHostView(model: model)
            model.reload()
        }
    }

    func load(_ url: URL) {
        if HistoryPageAddress.matches(url) { return reload() }
        onNavigate?(url)
    }

    func reload() {
        if let webPage { return webPage.reload() }
        model.reload()
    }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        if let webPage { return webPage.focusPage() }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        // The React page stays current from the owner's change events; the native one re-reads.
        if visible, webPage == nil { model.reload() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        if let webPage {
            await webPage.send(command: "find", arguments: ["text": .string(text)])
            return .none
        }
        model.text = text
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
