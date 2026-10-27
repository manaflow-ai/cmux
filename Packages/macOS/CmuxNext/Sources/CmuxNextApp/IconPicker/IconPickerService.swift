import AppKit
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextSignposts
import CmuxNextWakeups

/// Shows the one icon picker (R94) in a floating panel beside its anchor and
/// reports the outcome. One warm picker (S3 d): the first open loads the page
/// into its panel; every later open reuses that panel, page
/// and provider (a session swap, no cold load), and a close only hides the panel.
/// With feature `memoryOverlayPagesOnFirstUse` (``OverlayPageRelease``) the launch makes no picker, and the
/// warm one goes once unused (five minutes after its close at the Memory Saver mode's medium), or at memory
/// pressure: the next open makes it again.
/// One picker at a time: a new open cancels the previous one. ``open`` is what
/// `debug.popups` lists, so preflights prove it opened.
@MainActor
final class IconPickerService {
    /// Eight large square tiles per row (the page derives the tile pitch from its width).
    static let size = NSSize(width: 600, height: 520)

    /// Where the picker opens: a rect in `view`'s coordinates (the sidebar row, or the top
    /// middle of the window).
    struct Anchor {
        let view: NSView
        let rect: NSRect
    }

    /// The open picker, for `debug.popups`.
    struct OpenPicker {
        let panel: IconPickerPanel
        let provider: IconPickerProvider
        let page: PageWebView
        /// `workspace:<id>`, `screen:<id>`, `screenGroup:<id>`, `tabGroup:<id>`, `space:<id>`, `browserProfile:<id>`, `machine:<id>`.
        let target: String
        /// The anchor in screen coordinates.
        let anchor: NSRect
        let parent: NSWindow?
    }

    /// The warm picker: the panel with its loaded page and the page's one provider.
    private struct Warm {
        let panel: IconPickerPanel
        let page: PageWebView
        let provider: IconPickerProvider
    }

    private(set) weak var services: AppServices?
    private lazy var prefs = IconPickerPrefsStore(services: services)
    private let symbols = IconPickerSymbols()
    /// The system SF Symbol catalog, loaded off the main actor at the first open; nil until then.
    private var catalog: IconPickerSymbolCatalog?
    /// The catalog read in flight: every caller that asks while it runs shares it.
    private var catalogLoad: Task<IconPickerSymbolCatalog, Never>?
    /// What runs once the catalog is loaded, by waiter: each waiter's reply is its own task in its own class (a pick
    /// `userBlocking`, the idle prepare `background`), so a pick never waits behind the prepare's class.
    private var catalogWaiters: [Int: () -> Void] = [:]
    private var nextCatalogWaiter = 0
    /// The app's main-thread scheduler: the catalog's reply and its waiters are posted tasks on it.
    private let mainWork: MainWorkScheduler
    private lazy var maxEmojiVersion = IconPickerSymbols.maxEmojiVersion()
    private(set) var open: OpenPicker?
    private var warm: Warm?
    /// Opens and closes the panel like every native popup (POLISH: calm motion).
    private let fade = PopupFade()

    /// Makes the picker's page (the app's one ``WebUIHost``).
    private let webUI: WebUIHost
    /// When the warm picker goes; nil keeps it for the process's life.
    private(set) var release: OverlayPageRelease?

    /// - Parameter release: The app's overlay page terms (feature `memoryOverlayPagesOnFirstUse`); nil keeps the
    ///   warm picker for good and lets the launch make it.
    init(services: AppServices?, webUI: WebUIHost, mainWork: MainWorkScheduler, release terms: OverlayPageReleaseTerms? = nil) {
        self.services = services
        self.webUI = webUI
        self.mainWork = mainWork
        release = terms?.release(owner: "iconPicker", inUse: { [weak self] in self?.isInUse ?? false }) { [weak self] in self?.dropWarm() }
    }

    /// Whether the panel, page and provider exist, so an open reuses them.
    var isWarm: Bool { warm != nil }

    /// Each open's timing (`debug.timings` lists them as `icon_picker_opens`).
    var onOpened: ((IconPickerOpenTiming) -> Void)?
    /// Where each open's `stall.icon_picker_open` slice goes (tests pass one over their own trace runtime).
    var stallSignposter: Signposter = .stall

    /// Makes the warm picker ahead of the first open (the app calls it at an idle moment after
    /// launch); `then` runs when it is ready. Under ``release`` it makes none before an open since the
    /// last release (``OverlayPageRelease/allowsPrewarm``).
    func prepare(then: (() -> Void)? = nil) {
        if let release, !release.allowsPrewarm {
            then?()
            return
        }
        guard let catalog else {
            loadCatalog(.background) { [weak self] in self?.prepare(then: then) }
            return
        }
        if warm == nil { _ = makeWarm(catalog: catalog) }
        then?()
    }

    /// Opens the picker at `anchor` for `target` (an object whose icon is `current`);
    /// `completion` runs once with the outcome (a cancel when the panel closes without a pick).
    /// `assets` is where the object's owner stores an Image or SVG pick; without it those tabs stay off.
    func pick(current: String?, target: String, at anchor: Anchor, assets: IconAssetStore? = nil,
              completion: @escaping (IconPickerResult) -> Void) {
        pick(current: current, target: target, at: anchor, assets: assets, started: .now, completion: completion)
    }

    private func pick(current: String?, target: String, at anchor: Anchor, assets: IconAssetStore?, started: ContinuousClock.Instant,
                      completion: @escaping (IconPickerResult) -> Void) {
        guard let catalog else {
            loadCatalog(.userBlocking) { [weak self] in
                self?.pick(current: current, target: target, at: anchor, assets: assets, started: started, completion: completion)
            }
            return
        }
        // The open's main-thread work, from the catalog in hand to the panel shown, is one thread slice (B/E):
        // a first open's catalog load runs off the main actor, before it.
        let slice = stallSignposter.begin(.stallIconPickerOpen)
        defer { stallSignposter.end(.stallIconPickerOpen, slice) }
        let catalogReady = ContinuousClock.now
        open?.provider.finish(.cancel)
        prefs.load()
        let createdPage = warm == nil
        guard let warm = warm ?? makeWarm(catalog: catalog) else {
            completion(.cancel)
            return
        }
        release?.didShow()
        let pageReady = ContinuousClock.now
        var session = IconPickerSession(id: UUID().uuidString, current: current)
        let dark = anchor.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        session.symbolStyle = IconPickerSymbols.style(dark: dark)
        warm.provider.begin(session, assets: assets) { [weak self] result in
            self?.close()
            completion(result)
        }
        let parent = anchor.view.window
        let screenAnchor = parent.map { $0.convertToScreen(anchor.view.convert(anchor.rect, to: nil)) } ?? anchor.rect
        let panel = warm.panel
        panel.setFrame(IconPickerPanel.frame(size: Self.size, anchor: screenAnchor, visible: parent?.screen?.visibleFrame), display: false)
        panel.onDismiss = { [weak provider = warm.provider] in provider?.finish(.cancel) }
        open = OpenPicker(panel: panel, provider: warm.provider, page: warm.page, target: target, anchor: screenAnchor, parent: parent)
        // Shown over its window (a child moves with it); never on screen for a window that is not
        // (tests, windows not ordered in).
        if let parent, parent.isVisible {
            fade.open(panel, over: parent, toward: screenAnchor)
            panel.makeKey()
            warm.page.focusPage()
        }
        onOpened?(IconPickerOpenTiming(catalog: started.duration(to: catalogReady), page: catalogReady.duration(to: pageReady),
                                       present: pageReady.duration(to: .now), createdPage: createdPage))
    }

    /// Loads the symbol catalog off the main actor (a few plist reads), then runs `then` as a task of `workClass`.
    /// One load serves every caller that asks while it runs; each caller's reply is posted in that caller's class.
    private func loadCatalog(_ workClass: BudgetedWorkClass, then: @escaping () -> Void) {
        let waiter = nextCatalogWaiter
        nextCatalogWaiter += 1
        catalogWaiters[waiter] = then
        // task-owner: one read per first open; it ends with the read, and every waiter's reply holds it
        let load = catalogLoad ?? Task { @concurrent in await IconPickerSymbolCatalog.load() }
        catalogLoad = load
        let mainWork = mainWork
        // task-owner: one wait per waiter; it ends when the shared read does, and the service outlives it weakly
        Task { @concurrent [weak self] in
            let loaded = await load.value
            mainWork.postFromAnyThread(workClass, owner: "IconPickerService.catalog") { [weak self] in
                self?.catalogLoaded(loaded, waiter: waiter)
            }
        }
    }

    private func catalogLoaded(_ loaded: IconPickerSymbolCatalog, waiter: Int) {
        if catalog == nil { catalog = loaded }
        catalogLoad = nil
        catalogWaiters.removeValue(forKey: waiter)?()
    }

    /// The picker page's engine options: it shows in a floating glass panel that closes when it
    /// loses the keys, and a Chromium page is an opaque child window that takes them.
    static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay)

    private func makeWarm(catalog: IconPickerSymbolCatalog) -> Warm? {
        let provider = IconPickerProvider(prefs: prefs, catalog: catalog, maxEmojiVersion: maxEmojiVersion)
        var routes = [PageRoute(prefix: "cmux.iconPicker.", provider: provider)]
        // Copy in the Actions menu: the shared clipboard op (the descriptor allows only that one).
        if let services { routes.append(PageRoute(prefix: "cmux.app.", provider: AppPageNativeProvider(services: services, page: .iconPicker))) }
        guard let page = webUI.open(PageOpenRequest(descriptor: .iconPicker, routes: routes, options: Self.engineOptions,
                                                    dynamicResources: symbols)) else { return nil }
        symbols.appearanceView = page
        let made = Warm(panel: IconPickerPanel(content: page, size: Self.size), page: page, provider: provider)
        warm = made
        release?.didMake()
        return made
    }

    /// Whether the picker is open or still fading out, so its release waits.
    private var isInUse: Bool { open != nil || fade.isClosing }

    /// The release's call, made only while the picker is neither open nor fading: ends the warm picker's page through
    /// its host and drops the panel and provider.
    private func dropWarm() {
        guard let warm else { return }
        self.warm = nil
        warm.panel.close()
        webUI.close(warm.page)
    }

    /// An anchor at workspace `id`'s sidebar row in the window that lists it, else the middle of
    /// the active window's content.
    func anchor(workspace id: String) -> Anchor? {
        guard let windows = services?.windows else { return nil }
        let lists = { (window: WindowController) in windows.registry.members(of: window.state.id).contains(id) }
        let controller = windows.active.flatMap { lists($0) ? $0 : nil } ?? windows.controllers.first(where: lists) ?? windows.active
        guard let controller, let content = controller.window?.contentView else { return nil }
        if let screen = controller.sidebar.container.sidebarView.rowFrameOnScreen(for: SidebarWorkspaceID(id)),
           let window = content.window {
            return Anchor(view: content, rect: content.convert(window.convertFromScreen(screen), from: nil))
        }
        return centerAnchor(in: content)
    }

    /// An anchor at personal group `id`'s header in the active window, else
    /// the middle of the active window's content.
    func anchor(group id: String) -> Anchor? {
        guard let controller = services?.windows.active, let content = controller.window?.contentView else { return nil }
        if let screen = controller.sidebar.container.sidebarView.groupRowFrameOnScreen(for: controller.sidebar.model.groupID(personal: id)),
           let window = content.window {
            return Anchor(view: content, rect: content.convert(window.convertFromScreen(screen), from: nil))
        }
        return centerAnchor(in: content)
    }

    /// An anchor at the top middle of the active window (objects with no row on screen).
    func activeWindowAnchor() -> Anchor? {
        services?.windows.active?.window?.contentView.map { centerAnchor(in: $0) }
    }

    private func centerAnchor(in content: NSView) -> Anchor {
        let bounds = content.bounds
        return Anchor(view: content, rect: NSRect(x: bounds.midX - 1, y: bounds.maxY - 80, width: 2, height: 2))
    }

    /// Fades the panel out; the page stays loaded for the next open, until ``release`` lets it go.
    private func close() {
        guard let open else { return }
        self.open = nil
        open.panel.onDismiss = nil
        fade.close(open.panel, toward: open.anchor)
        release?.didHide()
    }
}

/// One icon picker open: waiting for the symbol catalog (a first open with no warm-up), making or
/// reusing the panel and page, and showing it.
struct IconPickerOpenTiming {
    let catalog: Duration
    let page: Duration
    let present: Duration
    /// The open made the panel and its page (no warm picker yet).
    let createdPage: Bool
    var total: Duration { catalog + page + present }
}
