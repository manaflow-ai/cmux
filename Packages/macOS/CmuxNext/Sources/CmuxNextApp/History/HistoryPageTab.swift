import AppKit
import CmuxNextBrowser
import CmuxNextHistory
import Foundation
import Observation

/// The `cmux://history` page in a browser tab (plans/cmux-next/history.md
/// 5.1): a native view, no engine. Navigating it to a web address asks the
/// host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class HistoryPageTab: BrowserTab, @unchecked Sendable {
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
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: any HistoryPageSource) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: HistoryPageAddress.url, title: HistoryPageStrings.title)
        state.phase = .finished
        self.state = state
        model = HistoryPageModel(source: source)
        contentView = HistoryPageHostView(model: model)
        model.reload()
    }

    func load(_ url: URL) {
        if HistoryPageAddress.matches(url) { return model.reload() }
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
        model.text = text
        return .none
    }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}

enum HistoryPageStrings {
    static var title: String { String(localized: "history.page.tabTitle", defaultValue: "History", table: "History", bundle: .module) }
}
