import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSidebar

/// Shows the one icon picker (R94) in a floating panel beside its anchor and
/// reports the outcome. The page loads in a new page view per open for now;
/// the shared prewarmed page host (plans/cmux-next/icons.md, step c) replaces
/// that cold load. One picker at a time: a new open cancels the previous one.
/// ``debugState`` is what `debug.popups` lists, so preflights prove it opened.
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
        guard let page = PageWebView(descriptor: .iconPicker, routes: routes, dynamicResources: symbols) else {
            completion(.cancel)
            return
        }
        let parent = anchor.view.window
        let screenAnchor = parent.map { $0.convertToScreen(anchor.view.convert(anchor.rect, to: nil)) } ?? anchor.rect
        let panel = IconPickerPanel(content: page, size: Self.size)
        panel.setFrame(IconPickerPanel.frame(size: Self.size, anchor: screenAnchor, visible: parent?.screen?.visibleFrame), display: false)
        panel.onDismiss = { [weak provider] in provider?.finish(.cancel) }
        open = OpenPicker(panel: panel, provider: provider, page: page, target: target, anchor: screenAnchor, parent: parent)
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
        open.page.close()
    }
}
