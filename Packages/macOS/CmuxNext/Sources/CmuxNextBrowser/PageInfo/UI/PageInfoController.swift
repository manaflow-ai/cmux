import AppKit
import CmuxNextDesign
import CmuxNextPages

/// Owns one browser pane's page info bubble (Chromium's `PageInfoBubbleView`)
/// and the windows it opens (certificate viewer, site settings, on-device
/// site data). Every user action is a `PageInfoCommand`; when
/// `commandRouter` is set, commands with a registry action go through it
/// (the App runs the action, whose handler calls `perform`), so a click and
/// `cmux browser page-info ...` take one path.
public final class PageInfoController {
    /// Makes the bubble's React page (webviews/src/pages/page-info); tests pass their own.
    var makeWebContent: @MainActor () -> (any BrowserChromeWebContent)? = { BrowserChromeWebHost(.pageInfo) }

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
    /// Card size the page last reported for its content (zero before its first report).
    private var cardSize = CGSize.zero
    /// The React page, made on the first open and kept between opens.
    private var content: (any BrowserChromeWebContent)?
    /// The bubble opens once the page reported the size of the state it was given, so it never
    /// shows a frame of the old page or grows after it appeared.
    private var presentsOnSize = false
    /// Counts the states sent to the page; a size report names the one it measured, so the bubble
    /// opens at the size of the newest state only.
    private var revision = 0
    /// Counts the bubble's openings; the page names the one whose state drew the control a
    /// command came from, so a command from an earlier opening (another site) is dropped.
    private var opening = 0
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
    /// Shown, or waiting for the page's size to show: state changes go to the page either way.
    var isOpen: Bool { isShown || presentsOnSize }

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
        if isOpen { close() } else { send(.show(.main)) }
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
        if !isOpen {
            opening += 1
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
        if !isOpen {
            presentsOnSize = true
            // A click outside, a deactivation or a window move before the page's size arrives
            // drops the open.
            popup.watchBeforeShowing(window)
        }
        render()
    }

    public func close() {
        guard isOpen else { return }
        popup.hide()
        closed()
    }

    /// Closes the bubble's panel for good (its page is closing): ``close()`` only orders it out.
    func closePanel() {
        isRetired = true
        content?.close()
        content = nil
        card.setContent(nil)
        certificateTask?.cancel()
        certificateTask = nil
        close()
        popup.closePanel()
        windows.closeAll()
    }

    /// The bubble closed (``close()`` or a host dismiss rule): live data stops, the page gets
    /// the keys back.
    private func closed() {
        presentsOnSize = false
        observation?.cancel()
        observation = nil
        loadTask?.cancel()
        if pageHadFocus { onReturnFocus?() }
    }

    private func present() {
        guard let panel, let anchor = anchorSource(), let window = anchor.window else { return }
        // The rows' icon column lines up with the omnibar button.
        anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).offsetBy(dx: -PageInfoStyle.rowInset, dy: 0)
        // The bubble takes the omnibar's theme scope (its room or workspace).
        panel.adoptThemeScope(of: anchor)
        guard let placed = popup.show(size: cardSize, anchor: anchorRect, in: window, preferred: anchor.toolbarPopupSide, makeKey: true) else { return close() }
        side = placed.side
        content?.focus()
    }

    /// Sends the model to the page; its size report places the bubble.
    func render() {
        guard let content = content ?? makeContent() else { return }
        revision += 1
        var state = model.wireState
        state["revision"] = revision
        state["opening"] = opening
        // The card's metrics at the current density, which the page lays its rows out with.
        state["metrics"] = ["width": PageInfoStyle.bubbleWidth, "row": PageInfoStyle.rowHeight,
                            "rowSubtitle": PageInfoStyle.rowHeightWithSubtitle, "padding": PageInfoStyle.inset / 2,
                            "rowInset": PageInfoStyle.rowInset]
        content.push(state)
    }

    private func makeContent() -> (any BrowserChromeWebContent)? {
        guard let made = makeWebContent() else { return nil }
        made.onMessage = { [weak self] kind, params in self?.received(kind, params) }
        card.setContent(made.view)
        content = made
        return made
    }

    private func received(_ kind: String, _ params: [String: Any]) {
        switch kind {
        case "command":
            // A command the page queued before a close or a navigation is for a site no longer shown.
            guard Self.acceptsPageCommand(isOpen: isOpen, opening: opening, from: (params["opening"] as? NSNumber)?.intValue,
                                          openedURL: openedURL, current: tab?.state.url),
                  let command = PageInfoCommand(wire: params) else { return }
            send(command)
        case "size":
            guard let height = (params["height"] as? NSNumber)?.doubleValue, height > 0,
                  (params["revision"] as? NSNumber)?.intValue == revision else { return }
            let size = CGSize(width: PageInfoStyle.bubbleWidth, height: ceil(height))
            let changed = size != cardSize
            cardSize = size
            // Every state push brings a report (the page's layout effect); only a change resizes.
            if presentsOnSize {
                presentsOnSize = false
                present()
            } else if changed, isShown, let window = panel?.parent {
                // An open bubble takes the new page's size at its place (the host keeps it open).
                popup.show(size: size, anchor: anchorRect, in: window, preferred: side)
            }
        default:
            break
        }
    }

    /// The page's commands act on the site the bubble shows: only while it is open (or opening),
    /// from a control this opening drew (`from`), and while the tab is still on the address it
    /// opened for.
    static func acceptsPageCommand(isOpen: Bool, opening: Int, from: Int?, openedURL: URL?, current: URL?) -> Bool {
        isOpen && from == opening && openedURL != nil && current == openedURL
    }

    private static func pageHasFocus(_ tab: any BrowserTab, in window: NSWindow) -> Bool {
        if let view = window.firstResponder as? NSView, view.isDescendant(of: tab.contentView) { return true }
        // A Chromium page is a key child window of `window`.
        return tab.presentation == .childWindow && (NSApp.keyWindow?.parent === window)
    }

    // MARK: Keyboard

    /// Escape closes from anywhere in the bubble; the page moves between its rows itself.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        close()
        return true
    }
}
