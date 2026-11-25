import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextWakeups

/// Shows the one icon picker (R94) in a floating panel beside its anchor and reports the outcome. One warm picker (S3 d):
/// the first open (or sign of intent) loads the page into its panel; every later open reuses that panel, page and provider
/// (a session swap, no cold load), and a close only hides the panel. One picker at a time: a new open cancels the previous
/// one. ``open`` is what `debug.popups` lists, so preflights prove it opened.
@MainActor
final class IconPickerService {
    /// Eight large square tiles per row (the page derives the tile pitch from its width).
    static let size = NSSize(width: 600, height: 520)

    /// Where the picker opens: a rect in `view`'s coordinates (the sidebar row, or the top middle of the window).
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
    /// The system SF Symbol catalog, loaded off the main actor at launch idle (`prepare(page: false)`); nil until then.
    private var catalog: IconPickerSymbolCatalog?
    private lazy var maxEmojiVersion = IconPickerSymbols.maxEmojiVersion()
    private(set) var open: OpenPicker?
    private var warm: Warm?
    /// Opens and closes the panel like every native popup (POLISH: calm motion).
    private let fade = PopupFade()
    /// Frees the warm picker after ``idleLimit`` with no open (`release`); the next sign of intent or open makes it again.
    private let idle = DemandTimer(owner: "IconPickerService.idleRelease")
    /// How long the warm page stays with no open before it is freed (its WebContent and WebKit GPU memory).
    /// `debug.overlay_open_bench` shortens it for a measurement; nil keeps the page for good.
    var idleLimit: Duration? = .seconds(10 * 60)
    /// A page made by the open itself shows once drawn, 1 s at most (`PageRevealGate`).
    private let reveal = PageRevealGate(owner: "IconPickerService.firstLoad"), firstLoadLimit: Duration = .seconds(1)

    init(services: AppServices?) {
        self.services = services
    }

    /// Whether the panel, page and provider exist, so an open reuses them; `isPageReady`: its page also drew the picker.
    var isWarm: Bool { warm != nil }
    var isPageReady: Bool { warm?.provider.isSubscribed == true }
    /// The open picker's panel is on screen; `drawn`: with its page drawn (the picker shows only once it is).
    var isCardShown: Bool { open.map { $0.panel.isVisible && $0.panel.alphaValue > 0 } ?? false }
    var isOpen: Bool { open != nil }
    func drawn(since start: ContinuousClock.Instant) -> Bool { isCardShown && isPageReady }
    func prepare() { prepare(page: true) }

    /// Each open's timing (`debug.timings` lists them as `icon_picker_opens`).
    var onOpened: ((IconPickerOpenTiming) -> Void)?

    /// Makes the warm picker ahead of the first open, on a sign of intent (the first menu or palette open), never at
    /// launch; `page: false` loads only the symbol catalog (no web page: the app does it at launch idle). `then` runs when ready.
    func prepare(page: Bool = true, then: (() -> Void)? = nil) {
        guard let catalog else { return loadCatalog { [weak self] in self?.prepare(page: page, then: then) } }
        if page, warm == nil { _ = makeWarm(catalog: catalog) }
        if page, open == nil { scheduleRelease() }
        then?()
    }

    /// Frees the panel, page and provider while no picker is open; the symbol catalog stays (no web page).
    func release() {
        idle.cancel()
        guard open == nil, let warm else { return }
        self.warm = nil
        reveal.cancel()
        warm.provider.onSubscribed = nil
        warm.panel.onDismiss = nil
        warm.panel.parent?.removeChildWindow(warm.panel)
        warm.panel.orderOut(nil)
        warm.page.close()
    }

    private func scheduleRelease() {
        guard let limit = idleLimit, warm != nil else { return }
        idle.schedule(after: limit) { @MainActor [weak self] in self?.release() }
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
            loadCatalog { [weak self] in
                self?.pick(current: current, target: target, at: anchor, assets: assets, started: started, completion: completion)
            }
            return
        }
        let catalogReady = ContinuousClock.now
        open?.provider.finish(.cancel)
        idle.cancel()
        prefs.load()
        let createdPage = warm == nil
        guard let warm = warm ?? makeWarm(catalog: catalog) else { return completion(.cancel) }
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
        // Shown over its window (a child moves with it), never for a window not on screen (tests); a page this open made
        // shows once its document drew the picker, never as a blank card (PageRevealGate).
        if let parent, parent.isVisible {
            reveal.hold(ready: warm.provider.isSubscribed, limit: firstLoadLimit) { [fade] in
                fade.open(panel, over: parent, toward: screenAnchor); panel.makeKey(); warm.page.focusPage()
            }
        }
        onOpened?(IconPickerOpenTiming(catalog: started.duration(to: catalogReady), page: catalogReady.duration(to: pageReady),
                                       present: pageReady.duration(to: .now), createdPage: createdPage))
    }

    /// Loads the symbol catalog off the main actor (a few plist reads), then runs `then`.
    private func loadCatalog(then: @escaping () -> Void) {
        // task-owner: one load per first open; it ends with the read, and the service outlives it weakly
        Task { [weak self] in
            let loaded = await IconPickerSymbolCatalog.load()
            guard let self else { return }
            if self.catalog == nil { self.catalog = loaded }
            then()
        }
    }

    /// The picker page's engine options: it shows in a floating glass panel that closes when it
    /// loses the keys, and a Chromium page is an opaque child window that takes them.
    static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay)

    private func makeWarm(catalog: IconPickerSymbolCatalog) -> Warm? {
        let provider = IconPickerProvider(prefs: prefs, catalog: catalog, maxEmojiVersion: maxEmojiVersion)
        var routes = [PageRoute(prefix: "cmux.iconPicker.", provider: provider)]
        // Copy in the Actions menu: the shared clipboard op (the descriptor allows only that one).
        if let services { routes.append(PageRoute(prefix: "cmux.app.", provider: AppPageNativeProvider(services: services, page: .iconPicker))) }
        guard let page = PageWebView(descriptor: .iconPicker, routes: routes, options: Self.engineOptions, dynamicResources: symbols, overlayProcess: services?.overlayProcess) else { return nil }
        symbols.appearanceView = page
        provider.onSubscribed = { [weak self] in self?.reveal.open() }
        let made = Warm(panel: IconPickerPanel(content: page, size: Self.size), page: page, provider: provider)
        warm = made
        return made
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

    /// Fades the panel out; the page stays loaded for the next open, until ``idleLimit`` passes with none.
    private func close() {
        reveal.cancel()
        guard let open else { return }
        self.open = nil
        open.panel.onDismiss = nil
        fade.close(open.panel, toward: open.anchor)
        scheduleRelease()
    }

    /// Cancels the open picker as a click outside does (`debug.overlay_open_bench`).
    func cancelOpen() {
        open?.provider.finish(.cancel)
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
