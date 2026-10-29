import AppKit
import CmuxNextBrowser
import Foundation
import Observation
import CmuxNextHistory

/// The `cmux://vault` page in a browser tab: the vault list as a native view,
/// no engine (like `HistoryPageTab`). Navigating it to a web address asks the
/// host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
final class VaultPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let vault: SessionVault
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, host: VaultHostView) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: VaultPageAddress.url, title: VaultStrings.title)
        state.phase = .finished
        self.state = state
        vault = host.vault
        contentView = host
    }

    func load(_ url: URL) {
        if VaultPageAddress.matches(url) { return reload() }
        onNavigate?(url)
    }

    func reload() {
        let vault = vault
        Task { await vault.reload() }
    }

    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { reload() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        vault.filter = text
        return .none
    }
    func clearFind() { vault.filter = "" }
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}
