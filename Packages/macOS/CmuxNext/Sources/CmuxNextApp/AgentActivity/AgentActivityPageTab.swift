import AppKit
import CmuxNextAgentActivity
import CmuxNextBrowser
import Foundation
import Observation

/// The `cmux://agent-activity` page in a browser tab: a native view, no
/// engine (like `HistoryPageTab`). Navigating it to a web address asks the
/// host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class AgentActivityPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let model: AgentActivityModel
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, source: any AgentActivitySource) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: AgentActivityPageAddress.url, title: AgentActivityPaneStrings.title)
        state.phase = .finished
        self.state = state
        model = AgentActivityModel(source: source)
        contentView = AgentActivityHostView(model: model, source: source)
        model.start()
    }

    func load(_ url: URL) {
        if AgentActivityPageAddress.matches(url) { return }
        onNavigate?(url)
    }

    func reload() {}
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        model.filter = text
        return .none
    }
    func clearFind() { model.filter = "" }
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}
