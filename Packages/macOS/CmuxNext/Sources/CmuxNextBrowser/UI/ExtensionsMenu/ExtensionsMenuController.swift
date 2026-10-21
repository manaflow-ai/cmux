import AppKit
import CmuxNextDesign

/// Owns one browser pane's Extensions bubble (Chrome's `ExtensionsMenuView`): the native popup
/// below the Extensions button, its rows, the per-extension context menu and the keyboard.
///
/// Opening is cheap by design (u2229, "this extensions context menu is also extremely laggy"):
/// - the bubble opens at once with the store's current list; the Chromium round trip that
///   refreshes it runs on the next main-actor turn and only changed rows re-render;
/// - rows are kept between opens and laid out by frames, without Auto Layout;
/// - icons are decoded once per file (``ExtensionIconCache``);
/// - the "more options" menu opens over the bubble, which stays open, instead of closing one
///   `NSMenu` (with its fade) and opening another.
@MainActor
final class ExtensionsMenuController {
    /// One entry of ``report``: what the bubble or its open context menu shows.
    struct ReportItem: Equatable {
        var title: String
        var identifier: String?
        var extensionID: String?
        var isEnabled: Bool
        var isSeparator = false
    }

    let content: ExtensionsMenuView
    let icons = ExtensionIconCache()
    private let card: ExtensionsMenuCardView
    private let panel = ExtensionsMenuPanel()
    private let popup: NativePopupHost
    private let style: ExtensionsMenuStyle
    private var observation: ObservationLoop?
    private weak var host: (any BrowserExtensionActionHosting)?
    private var handler: (any ExtensionMenuHandling)?
    private weak var anchorView: NSView?
    private var anchorRect = CGRect.zero
    private var refreshTask: Task<Void, Never>?
    /// The context menu while it is open (over the bubble or at a toolbar icon).
    private(set) weak var presentedContextMenu: NSMenu?
    /// The view that toggles the bubble (the Extensions button): a press on it is no dismiss.
    var toggleView: () -> NSView? = { nil }
    /// The bubble opened (true) or closed (false) at this anchor: the toolbar holds the
    /// Extensions button pressed while it is open, as Chrome does.
    var onShownChange: ((NSView, Bool) -> Void)?
    /// Whether ``onShownChange`` last reported the bubble open.
    private var reportedShown = false
    /// Renders done since the bubble opened (a test seam).
    private(set) var renders = 0

    init(style: ExtensionsMenuStyle = .chrome) {
        self.style = style
        content = ExtensionsMenuView(style: style)
        card = ExtensionsMenuCardView(content: content, style: style)
        popup = NativePopupHost(panel: panel)
        panel.adoptPopupStyle(card: card).cornerRadius = style.cornerRadius
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        popup.keepsOpen = { [weak self] event in
            guard let button = self?.toggleView(), event.window === button.window else { return false }
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
        popup.onDismiss = { [weak self] in self?.closed() }
        content.actions = ExtensionsMenuView.Actions(
            run: { [weak self] id in self?.run(id) },
            pin: { [weak self] id, pinned in self?.handler?.perform(pinned ? .pin : .unpin, extensionID: id) },
            more: { [weak self] id, view in self?.showContextMenu(for: id, at: view, source: .menuItem) },
            manage: { [weak self] in self?.closeThen { $0.perform(.manage, extensionID: nil) } },
            close: { [weak self] in self?.close() }
        )
    }

    /// The bubble is on screen (a bubble fading out counts as closed).
    var isShown: Bool { popup.isShown }

    /// The extensions the bubble lists: the enabled ones, as Chrome's toolbar model does, by
    /// name (the store's order).
    static func listed(_ host: any BrowserExtensionActionHosting) -> [BrowserExtensionInfo] {
        ExtensionsMenu().extensions(of: host)
    }

    // MARK: Showing

    /// The Extensions button: opens the bubble, or closes it when it is open.
    func toggle(host: any BrowserExtensionActionHosting, handler: any ExtensionMenuHandling, anchor: NSView) {
        if isShown { close() } else { show(host: host, handler: handler, anchor: anchor) }
    }

    /// Opens the bubble below `anchor`, right-aligned to it (Chrome's `TOP_RIGHT` arrow).
    func show(host: any BrowserExtensionActionHosting, handler: any ExtensionMenuHandling, anchor: NSView) {
        guard let window = anchor.window else { return }
        self.host = host
        self.handler = handler
        anchorView = anchor
        renders = 0
        // Renders now, then again when the extensions or their toolbar state change while open.
        observation?.cancel()
        observation = ObservationLoop { [weak self] in
            guard let self, let host = self.host else { return }
            _ = host.extensionStore.extensions
            _ = host.extensionActions
            self.render()
        }
        anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.adoptThemeScope(of: anchor)
        guard popup.show(size: content.frame.size, anchor: anchorRect, in: window, preferred: .below, trailing: true,
                         makeKey: true) != nil else { return closed() }
        panel.makeFirstResponder(card)
        reportedShown = true
        onShownChange?(anchor, true)
        // The open does not wait for Chromium: the refresh runs on the next turn.
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isShown else { return }
            self.host?.extensionStore.refresh()
        }
    }

    /// Builds the rows and decodes the icons ahead of a click, so an open only shows the panel
    /// (u2426: "menu visible within one frame"). The toolbar calls it after a tab binds and when
    /// its extensions change, on a later main-actor turn.
    func prepare(host: any BrowserExtensionActionHosting) {
        guard !isShown else { return }
        self.host = host
        render()
        content.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        warmPanel()
    }

    /// Whether the panel has been on screen once.
    private var panelWarm = false

    /// Orders the panel in once, invisible and without the keys, so the window server builds its
    /// backing store and the glass before the first click; that first order-in was most of a
    /// cold open.
    private func warmPanel() {
        guard !panelWarm, !panel.isVisible else { return }
        panelWarm = true
        let alpha = panel.alphaValue
        panel.alphaValue = 0
        panel.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: content.frame.size), display: false)
        panel.orderFront(nil)
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = alpha
    }

    /// Rebuilds the rows that changed and resizes an open bubble in place.
    func render() {
        guard let host else { return }
        renders += 1
        let store = host.extensionStore
        let pngs = Dictionary(host.extensionActions.map { ($0.id, $0.iconPNG) }, uniquingKeysWith: { first, _ in first })
        let builtInAdBlocker = CEFRuntime.shared.builtInAdBlockerLoaded
        let before = content.frame.size
        content.update(
            Self.listed(host),
            icon: { [icons] info in icons.image(for: info, png: pngs[info.id] ?? nil) },
            canPin: { info in info.hasAction && store.supportsManagement },
            // The Web Store lists only uBlock Origin Lite; the full one ships inside cmux.
            tooltip: { info in builtInAdBlocker && info.id == CEFBuiltInExtensions.adBlockerID ? Strings.builtInAdBlocker : nil }
        )
        content.layoutSubtreeIfNeeded()
        if isShown, content.frame.size != before, let window = panel.parent {
            popup.show(size: content.frame.size, anchor: anchorRect, in: window, preferred: .below, trailing: true)
        }
    }

    func close() {
        guard isShown else { return }
        popup.hide()
        closed()
    }

    /// Closes the bubble, then runs `work` with the handler (an item that opens a page, a popup
    /// or Chromium's own menu must not open under the bubble).
    private func closeThen(_ work: @escaping (any ExtensionMenuHandling) -> Void) {
        guard let handler else { return }
        close()
        work(handler)
    }

    private func closed() {
        if reportedShown, let anchorView {
            reportedShown = false
            onShownChange?(anchorView, false)
        }
        observation?.cancel()
        observation = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: Rows

    /// The primary button: runs the extension's action (its popup hangs off the Extensions
    /// button), or, for an extension without an action, shows its context menu (Chrome shows the
    /// menu for a disabled action).
    private func run(_ id: String) {
        guard let info = host.map(Self.listed)?.first(where: { $0.id == id }) else { return }
        guard info.hasAction else {
            if let row = content.row(for: id) { showContextMenu(for: id, at: row.moreButton, source: .menuItem) }
            return
        }
        closeThen { $0.perform(.run, extensionID: id) }
    }

    /// Shows extension `id`'s context menu below `view` (Chrome anchors it `kTopLeft` to the
    /// button). From the bubble, it opens over the bubble on the next run-loop turn, so the
    /// caller (a click, the CLI) returns first; the bubble stays open behind it.
    func showContextMenu(for id: String, at view: NSView, source: ExtensionContextMenuModel.Source) {
        guard let host, let handler, let info = Self.listed(host).first(where: { $0.id == id }) else { return }
        let model = ExtensionContextMenuModel(info: info, supportsManagement: host.extensionStore.supportsManagement, source: source)
        let menu = model.menu(extensionID: id, title: info.name, handler: ClosingHandler(controller: self, inner: handler))
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self, weak view] in
            MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                guard let self, let view, view.window != nil else { return }
                self.presentedContextMenu = menu
                menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: view, gap: 0), in: view)
                self.presentedContextMenu = nil
                (view as? ExtensionsMenuHoverButton)?.refreshHover()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: Keyboard

    /// Escape closes; the arrow keys and Tab walk the bubble's buttons, as Chrome's arrow-key
    /// traversal does.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            close()
            return true
        case 125, 124:
            moveFocus(by: 1)
            return true
        case 126, 123:
            moveFocus(by: -1)
            return true
        case 48:
            moveFocus(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        default:
            return false
        }
    }

    /// Moves the keyboard highlight `offset` buttons along the bubble's order, wrapping.
    func moveFocus(by offset: Int) {
        let order = content.focusOrder.filter { !$0.isHidden && ($0 as? ExtensionsMenuHoverButton)?.isEnabled != false }
        guard !order.isEmpty else { return }
        let current = (panel.firstResponder as? NSView).flatMap { responder in order.firstIndex { $0 === responder } }
        let next: Int = if let current {
            (current + offset + order.count) % order.count
        } else {
            offset > 0 ? 0 : order.count - 1
        }
        panel.makeFirstResponder(order[next])
        content.reveal(order[next])
    }

    /// The button that has the keyboard highlight.
    var focusedButton: NSView? { panel.firstResponder as? ExtensionsMenuHoverButton }

    // MARK: Reports (`debug.extensions.menu`, UI tests)

    /// The open context menu's items, else the bubble's rows and footer; nil when closed.
    var report: [ReportItem]? {
        if let menu = presentedContextMenu {
            return menu.items.map { item in
                item.isSeparatorItem ? ReportItem(title: "-", isEnabled: false, isSeparator: true)
                    : ReportItem(title: item.title, identifier: item.identifier?.rawValue, isEnabled: item.isEnabled)
            }
        }
        guard isShown else { return nil }
        var items = content.rows.map { row in
            ReportItem(title: row.info.name, identifier: ExtensionsMenu.rowIdentifier(row.extensionID),
                       extensionID: row.extensionID, isEnabled: row.primary.isEnabled)
        }
        items.append(ReportItem(title: "-", isEnabled: false, isSeparator: true))
        items.append(ReportItem(title: Strings.extensionMenuTitle(.manage), identifier: ExtensionsMenu.footerIdentifier(.manage),
                                isEnabled: true))
        return items
    }

    /// Chooses an item as a click would: a row control (`run`, `pin`, `unpin`, `more`) of
    /// extension `id`, `manage`, `close`, or an operation of the open context menu. False when no
    /// item matches.
    func choose(_ operation: String, extension id: String?) -> Bool {
        if let menu = presentedContextMenu, let id,
           let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "\(ExtensionsMenu.moreIdentifier(id)).\(operation)" }) {
            menu.cancelTracking()
            menu.performActionForItem(at: index)
            return true
        }
        guard isShown else { return false }
        if let id, let row = content.row(for: id) {
            switch operation {
            case "run": row.primary.onPress?(); return true
            case "more": row.moreButton.onPress?(); return true
            case "pin", "unpin":
                if (operation == "pin") != row.isPinned { row.togglePin() }
                return true
            default: break
            }
        }
        switch operation {
        case "manage": content.manageButton.onPress?(); return true
        case "close": close(); return true
        default: return false
        }
    }

    /// Closes the open context menu, else the bubble.
    func dismiss() {
        if let menu = presentedContextMenu { menu.cancelTracking() } else { close() }
    }
}

/// Runs a context menu's choices: Pin and Unpin keep the bubble open (Chrome), every other
/// choice opens a page, a dialog or Chromium's own menu, so the bubble closes first.
@MainActor
private final class ClosingHandler: ExtensionMenuHandling {
    weak var controller: ExtensionsMenuController?
    let inner: any ExtensionMenuHandling

    init(controller: ExtensionsMenuController, inner: any ExtensionMenuHandling) {
        self.controller = controller
        self.inner = inner
    }

    func title(for operation: ExtensionMenuOperation) -> String { inner.title(for: operation) }

    func perform(_ operation: ExtensionMenuOperation, extensionID: String?) {
        if operation != .pin, operation != .unpin { controller?.close() }
        inner.perform(operation, extensionID: extensionID)
    }
}
