import AppKit
import CmuxNextDesign

/// Owns one browser pane's page info bubble (Chromium's `PageInfoBubbleView`)
/// and the windows it opens (certificate viewer, site settings, on-device
/// site data). Every user action is a `PageInfoCommand`; when
/// `commandRouter` is set, commands with a registry action go through it
/// (the App runs the action, whose handler calls `perform`), so a click and
/// `cmux browser page-info ...` take one path.
public final class PageInfoController {
    /// Returns true when the App ran the command through the action registry.
    public var commandRouter: ((PageInfoCommand) -> Bool)?
    /// The bubble closed; the page had keyboard focus when it opened.
    var onReturnFocus: (() -> Void)?

    public let model = PageInfoModel()

    private let tabSource: () -> (any BrowserTab)?
    private let anchorSource: () -> NSView?
    /// The shared native popup host: placement, motion and the dismiss rules (REUSE.md slice 3).
    private let popup: NativePopupHost
    private var panel: PageInfoPanel? { popup.panel as? PageInfoPanel }
    /// The omnibar button on screen, where the bubble grows from and shrinks to.
    private var anchorRect = CGRect.zero
    /// The side the bubble opened on; a new page keeps it (no flip while open).
    private var side = PopupPlacement.Side.below
    private let card = PageInfoCardView()
    var observation: ObservationLoop?
    var loadTask: Task<Void, Never>?
    var certificateTask: Task<Void, Never>?
    var isRetired = false
    var livePermissions: [SitePermissionKind: SitePermissionSetting] = [:]
    var openedURL: URL?
    private var pageHadFocus = false
    /// Card size for the rendered page.
    private var cardSize = CGSize.zero
    var windows = PageInfoWindows()

    init(tab: @escaping () -> (any BrowserTab)?, anchor: @escaping () -> NSView?) {
        tabSource = tab
        anchorSource = anchor
        let panel = PageInfoPanel()
        popup = NativePopupHost(panel: panel)
        panel.adoptPopupStyle(card: card)
        // The page's shell window: its windows open on that screen.
        windows.parentWindow = { anchor()?.window.map { $0.parent ?? $0 } }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        // A press on the omnibar button toggles the bubble: the button closes it, not the host.
        popup.keepsOpen = { event in
            guard let button = anchor(), event.window === button.window else { return false }
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
        popup.onDismiss = { [weak self] in self?.closed() }
    }

    /// A bubble fading out counts as closed: the button opens it again.
    public var isShown: Bool { popup.isShown }

    var tab: (any BrowserTab)? { tabSource() }
    var provider: (any PageInfoProviding)? { tab as? any PageInfoProviding }

    var store: SitePermissionStore? {
        guard let tab, let provider else { return nil }
        return provider.pageInfoSettings.permissions(for: tab.profileID)
    }

    // MARK: Entry points

    /// The omnibar button: opens the bubble, or closes it when open (a press on the button is no
    /// dismiss for the host, ``NativePopupHost/keepsOpen``).
    public func toggle() {
        if isShown { close() } else { send(.show(.main)) }
    }

    /// Sends a UI command: through the registry when routed, else directly.
    func send(_ command: PageInfoCommand) {
        if command.action != nil, let commandRouter, commandRouter(command) { return }
        perform(command)
    }

    /// Runs a command (the registry handlers call this).
    public func perform(_ command: PageInfoCommand) {
        guard !isRetired else { return }
        switch command {
        case .show(let page): show(page)
        case .close: close()
        case .reload:
            tab?.reload()
            close()
        default: performSiteCommand(command)
        }
    }

    /// The pane shows another tab: a bubble for the old one closes.
    public func tabDidChange() {
        close()
        certificateTask?.cancel()
        certificateTask = nil
        windows.closeAll()
    }

    // MARK: Showing

    private func show(_ page: PageInfoPage) {
        guard let tab, let anchor = anchorSource(), let window = anchor.window else { return }
        let site = PageInfoSite(state: tab.state)
        guard site.kind != .empty else { return }
        if !isShown {
            openedURL = tab.state.url
            pageHadFocus = Self.pageHasFocus(tab, in: window)
            model.site = site
            model.needsReload = false
            model.siteData = nil
            model.certificates = nil
            startObserving()
            loadAsyncData()
        }
        model.page = page
        render()
        present(in: window, anchor: anchor)
    }

    public func close() {
        guard isShown else { return }
        popup.hide()
        closed()
    }

    /// Closes the bubble's panel for good (its page is closing): ``close()`` only orders it out.
    func closePanel() {
        isRetired = true
        certificateTask?.cancel()
        certificateTask = nil
        close()
        popup.closePanel()
        windows.closeAll()
    }

    /// The bubble closed (``close()`` or a host dismiss rule): live data stops, the page gets
    /// the keys back.
    private func closed() {
        observation?.cancel()
        observation = nil
        loadTask?.cancel()
        if pageHadFocus { onReturnFocus?() }
    }

    private func present(in window: NSWindow, anchor: NSView) {
        guard let panel else { return }
        // The rows' icon column lines up with the omnibar button.
        anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).offsetBy(dx: -PageInfoStyle.rowInset, dy: 0)
        // The bubble takes the omnibar's theme scope (its room or workspace).
        panel.adoptThemeScope(of: anchor)
        guard let placed = popup.show(size: cardSize, anchor: anchorRect, in: window, preferred: anchor.toolbarPopupSide, makeKey: true) else { return }
        side = placed.side
        panel.makeFirstResponder(card)
    }

    /// Rebuilds the current page, keeping keyboard focus on the same row.
    func render() {
        let focused = (panel?.firstResponder as? NSView)?.identifier
        let content = PageInfoPages(model: model, send: { [weak self] in self?.send($0) }).build()
        let size = card.setContent(content)
        // An open bubble takes the new page's size at its place (the host keeps it open).
        if size != cardSize, isShown, let window = panel?.parent {
            cardSize = size
            popup.show(size: size, anchor: anchorRect, in: window, preferred: side)
        }
        cardSize = size
        if let focused, let row = Self.find(focused, in: content) { panel?.makeFirstResponder(row) }
    }

    private static func find(_ identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        for child in view.subviews { if let hit = find(identifier, in: child) { return hit } }
        return nil
    }

    private static func pageHasFocus(_ tab: any BrowserTab, in window: NSWindow) -> Bool {
        if let view = window.firstResponder as? NSView, view.isDescendant(of: tab.contentView) { return true }
        // A Chromium page is a key child window of `window`.
        return tab.presentation == .childWindow && (NSApp.keyWindow?.parent === window)
    }

    // MARK: Keyboard

    /// Escape closes; Up and Down move between rows like Tab.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            close()
            return true
        case 125:
            panel?.selectNextKeyView(nil)
            return true
        case 126:
            panel?.selectPreviousKeyView(nil)
            return true
        case 123 where model.page != .main:
            send(.show(.main))
            return true
        default:
            return false
        }
    }
}
