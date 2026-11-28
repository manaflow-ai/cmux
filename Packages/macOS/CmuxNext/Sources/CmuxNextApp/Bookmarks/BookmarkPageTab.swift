import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation
import Observation

/// The `cmux://bookmarks` manager in a browser tab: a native view, no engine
/// (works in builds without Chromium). Navigating it to a web address asks
/// the host (`onNavigate`) to turn the tab into a real page.
@Observable
final class BookmarkPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: BookmarkManagerModel
    @ObservationIgnored let source: BookmarkManagerSourceAdapter
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: BookmarkManagerSourceAdapter) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: BookmarkPageAddress.url, title: BookmarkStrings.pageTitle)
        state.phase = .finished
        self.state = state
        self.source = source
        model = BookmarkManagerModel(source: source)
        contentView = BookmarkManagerHostView(model: model)
    }

    func load(_ url: URL) {
        if BookmarkPageAddress.matches(url) { return model.reload() }
        onNavigate?(url)
    }

    func reload() { model.reload() }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { model.reload() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        model.query = text
        return .none
    }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}
