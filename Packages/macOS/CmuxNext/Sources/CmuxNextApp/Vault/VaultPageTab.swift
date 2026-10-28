import AppKit
import CmuxNextBrowser
import CmuxNextDesign
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
    /// The scroll position a hibernation saved, for the rebuilt page's first show.
    @ObservationIgnored let scrollRestore = BrowserAppPageScroll()

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
        vault.startReload()
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
        if visible { showSavedScroll() } else { scrollRestore.pageDidHide() }
    }

    func snapshot() async throws -> CGImage {
        // A hidden page's SwiftUI is out of the window (feature visibilityGatedHosting): this draws it too.
        guard let image = contentView.cachedDisplayImage() else { throw BrowserTabError.snapshotUnavailable }
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
    func close() { scrollRestore.cancel() }
}

/// Hibernates as a web page does (`memoryDiscardPageTabs`): the list's scroll goes with the tab.
/// Its search and picked row live on the app's one vault, which the right sidebar and every vault
/// tab show and which outlives the page: a wake leaves them as they are now.
extension VaultPageTab: BrowserAppPage {
    var pageAddress: URL { state.url ?? VaultPageAddress.url }
    var drawsInFirstFrame: Bool { true }

    func saveViewState() async -> BrowserAppPageState {
        BrowserAppPageState(url: pageAddress, scroll: scrollRestore.position(of: listScrollView))
    }

    func restoreViewState(_ saved: BrowserAppPageState) {
        scrollRestore.restore(saved.scroll)
    }

    /// The session list, the page's one scroll view.
    private var listScrollView: NSScrollView? { BrowserAppPageScroll.soleScrollView(in: contentView) }

    /// A saved scroll goes back once the list holds it; the sessions load after the show.
    private func showSavedScroll() {
        scrollRestore.pageDidShow(list: { [weak self] in self?.listScrollView }, hasRows: { [vault] in !vault.shownRows.isEmpty })
    }
}
