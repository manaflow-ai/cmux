import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSidebar

/// Shows the one icon picker (R94) in a floating panel beside its anchor and
/// reports the outcome. One warm picker (S3 d): the first open loads the page
/// into its panel; every later open reuses that panel, page
/// and provider (a session swap, no cold load), and a close only hides the panel.
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
        /// `workspace:<id>`, `screen:<id>`, `space:<id>`, `browserProfile:<id>`.
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

    private weak var services: AppServices?
    private lazy var prefs = IconPickerPrefsStore(services: services)
    private let symbols = IconPickerSymbols()
    /// The system SF Symbol catalog, loaded off the main actor at the first open; nil until then.
    private var catalog: IconPickerSymbolCatalog?
    private lazy var maxEmojiVersion = IconPickerSymbols.maxEmojiVersion()
    private(set) var open: OpenPicker?
    private var warm: Warm?

    init(services: AppServices) {
        self.services = services
    }

    /// Opens the picker at `anchor` for `target` (an object whose icon is `current`);
    /// `completion` runs once with the outcome (a cancel when the panel closes without a pick).
    func pick(current: String?, target: String, at anchor: Anchor, completion: @escaping (IconPickerResult) -> Void) {
        guard let catalog else {
            loadCatalog { [weak self] in self?.pick(current: current, target: target, at: anchor, completion: completion) }
            return
        }
        open?.provider.finish(.cancel)
        prefs.load()
        guard let warm = warm ?? makeWarm(catalog: catalog) else {
            completion(.cancel)
            return
        }
        var session = IconPickerSession(id: UUID().uuidString, current: current)
        let dark = anchor.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        session.symbolStyle = IconPickerSymbols.style(dark: dark)
        warm.provider.begin(session) { [weak self] result in
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
        guard let parent, parent.isVisible else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        warm.page.focusPage()
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

    private func makeWarm(catalog: IconPickerSymbolCatalog) -> Warm? {
        let provider = IconPickerProvider(prefs: prefs, catalog: catalog, maxEmojiVersion: maxEmojiVersion)
        var routes = [PageRoute(prefix: "cmux.iconPicker.", provider: provider)]
        // Copy in the Actions menu: the shared clipboard op (the descriptor allows only that one).
        if let services { routes.append(PageRoute(prefix: "cmux.app.", provider: AppPageNativeProvider(services: services, page: .iconPicker))) }
        guard let page = PageWebView(descriptor: .iconPicker, routes: routes, dynamicResources: symbols) else { return nil }
        symbols.appearanceView = page
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
        guard let controller = services?.windows?.active, let content = controller.window?.contentView else { return nil }
        if let screen = controller.sidebar.container.sidebarView.groupRowFrameOnScreen(for: CmuxNextSidebar.GroupID(id)),
           let window = content.window {
            return Anchor(view: content, rect: content.convert(window.convertFromScreen(screen), from: nil))
        }
        return centerAnchor(in: content)
    }

    /// An anchor at the top middle of the active window (objects with no row on screen).
    func activeWindowAnchor() -> Anchor? {
        services?.windows?.active?.window?.contentView.map { centerAnchor(in: $0) }
    }

    private func centerAnchor(in content: NSView) -> Anchor {
        let bounds = content.bounds
        return Anchor(view: content, rect: NSRect(x: bounds.midX - 1, y: bounds.maxY - 80, width: 2, height: 2))
    }

    /// Hides the panel; the page stays loaded for the next open.
    private func close() {
        guard let open else { return }
        self.open = nil
        open.panel.onDismiss = nil
        open.parent?.removeChildWindow(open.panel)
        open.panel.orderOut(nil)
    }
}
