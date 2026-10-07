import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSidebar

/// Shows the one icon picker (R94) in a floating panel beside its anchor and
/// reports the outcome. The picker opens in the app's prewarmed page host
/// (``PageHostPool``, plans/cmux-next/react-pages.md 1.4): the host was loaded
/// and the picker mounted ahead of the open, so an open only hands it the
/// session. With no ready host (the first open of a run, or a host still
/// warming) the page loads in its own view. Closing gives the host back to the
/// pool, which retires a used host and parks an untouched one again. One picker
/// at a time: a new open cancels the previous one. ``open`` is what
/// `debug.popups` lists, so preflights prove it opened.
@MainActor
final class IconPickerService {
    static let size = NSSize(width: 420, height: 460)

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
        /// The page is the pool's host (else a view of its own).
        let pooled: Bool
        /// `workspace:<id>`, `screen:<id>`, `space:<id>`, `browserProfile:<id>`.
        let target: String
        /// The anchor in screen coordinates.
        let anchor: NSRect
        let parent: NSWindow?
    }

    private weak var services: AppServices?
    private lazy var prefs = IconPickerPrefsStore(services: services)
    private let symbols = IconPickerSymbols()
    /// Loaded off the main actor at the first open; nil until then.
    private var symbolNames: [String]?
    private lazy var maxEmojiVersion = IconPickerSymbols.maxEmojiVersion()
    private(set) var open: OpenPicker?
    /// The app's one prewarmed page host for shell pages (R94, react-pages.md 1.4). The icon picker
    /// is the only shell page today, so its service owns the pool (AppServices is at its size limit).
    let pageHosts = PageHostPool()
    /// Serves the picker mounted in the parked host before its open: prefs only, no session.
    private lazy var preparedProvider = IconPickerProvider(session: nil, prefs: prefs) { _ in }

    init(services: AppServices) {
        self.services = services
    }

    /// Opens the picker at `anchor` for `target` (an object whose icon is `current`);
    /// `completion` runs once with the outcome (a cancel when the panel closes without a pick).
    func pick(current: String?, target: String, at anchor: Anchor, completion: @escaping (IconPickerResult) -> Void) {
        guard let symbolNames else {
            // First open: the symbol names load off the main actor (two file reads), then the picker shows.
            // task-owner: one load per first open; it ends with the read, and the service outlives it weakly
            Task { [weak self] in
                let names = await IconPickerSymbols.names()
                guard let self else { return }
                self.symbolNames = names
                self.pick(current: current, target: target, at: anchor, completion: completion)
            }
            return
        }
        open?.provider.finish(.cancel)
        prefs.load()
        let session = IconPickerSession(id: UUID().uuidString, current: current, symbols: symbolNames, maxEmojiVersion: maxEmojiVersion)
        let provider = IconPickerProvider(session: session, prefs: prefs) { [weak self] result in
            self?.close()
            completion(result)
        }
        let routes = [PageRoute(prefix: "cmux.iconPicker.", provider: provider)]
        let parent = anchor.view.window
        let warm = pageHosts.claim(.iconPicker, routes: routes, context: session.event, dynamicResources: symbols, window: parent)
        // The next open finds the picker mounted in a parked host at the panel's size.
        pageHosts.prepare(.iconPicker, routes: [PageRoute(prefix: "cmux.iconPicker.", provider: preparedProvider)],
                          dynamicResources: symbols, size: Self.size)
        guard let page = warm ?? PageWebView(descriptor: .iconPicker, routes: routes, dynamicResources: symbols) else {
            completion(.cancel)
            return
        }
        let screenAnchor = parent.map { $0.convertToScreen(anchor.view.convert(anchor.rect, to: nil)) } ?? anchor.rect
        let panel = IconPickerPanel(content: page, size: Self.size)
        panel.setFrame(IconPickerPanel.frame(size: Self.size, anchor: screenAnchor, visible: parent?.screen?.visibleFrame), display: false)
        panel.onDismiss = { [weak provider] in provider?.finish(.cancel) }
        // A pooled host that crashes reloads the bare shell, not the picker: end the session.
        if warm != nil { page.onCrash = { [weak provider] _, _ in provider?.finish(.cancel) } }
        open = OpenPicker(panel: panel, provider: provider, page: page, pooled: warm != nil, target: target,
                          anchor: screenAnchor, parent: parent)
        // Shown over its window (a child moves with it); never on screen for a window that is not
        // (tests, windows not ordered in).
        guard let parent, parent.isVisible else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        page.focusPage()
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

    /// An anchor at the top middle of the active window (objects with no row on screen).
    func activeWindowAnchor() -> Anchor? {
        services?.windows?.active?.window?.contentView.map { centerAnchor(in: $0) }
    }

    private func centerAnchor(in content: NSView) -> Anchor {
        let bounds = content.bounds
        return Anchor(view: content, rect: NSRect(x: bounds.midX - 1, y: bounds.maxY - 80, width: 2, height: 2))
    }

    private func close() {
        guard let open else { return }
        self.open = nil
        open.panel.onDismiss = nil
        open.parent?.removeChildWindow(open.panel)
        open.panel.orderOut(nil)
        if open.pooled {
            pageHosts.release(open.page)
        } else {
            open.page.close()
        }
    }
}
