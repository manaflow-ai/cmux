import AppKit
import CmuxNextDesign

/// Owns one browser pane's page info bubble (Chrome's `PageInfoBubbleView`)
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
    private var panel: PageInfoPanel?
    private let card = PageInfoCardView()
    var observation: ObservationLoop?
    var loadTask: Task<Void, Never>?
    var livePermissions: [SitePermissionKind: SitePermissionSetting] = [:]
    var openedURL: URL?
    private var pageHadFocus = false
    /// Panel size for the rendered page (card plus shadow margin).
    private var cardSize = CGSize.zero
    private var dismissedByMouseDown: Int?
    var windows = PageInfoWindows()

    init(tab: @escaping () -> (any BrowserTab)?, anchor: @escaping () -> NSView?) {
        tabSource = tab
        anchorSource = anchor
        // The page's shell window: its windows open on that screen.
        windows.parentWindow = { anchor()?.window.map { $0.parent ?? $0 } }
    }

    public var isShown: Bool { panel?.isVisible ?? false }

    var tab: (any BrowserTab)? { tabSource() }
    var provider: (any PageInfoProviding)? { tab as? any PageInfoProviding }

    var store: SitePermissionStore? {
        guard let tab, let provider else { return nil }
        return provider.pageInfoSettings.permissions(for: tab.profileID)
    }

    // MARK: Entry points

    /// The omnibar button: opens the bubble, or closes it when open. A press
    /// whose mouse-down already closed the bubble does not reopen it.
    public func toggle() {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.eventNumber == dismissedByMouseDown {
            dismissedByMouseDown = nil
            return
        }
        if isShown { close() } else { send(.show(.main)) }
    }

    /// Sends a UI command: through the registry when routed, else directly.
    func send(_ command: PageInfoCommand) {
        if command.action != nil, let commandRouter, commandRouter(command) { return }
        perform(command)
    }

    /// Runs a command (the registry handlers call this).
    public func perform(_ command: PageInfoCommand) {
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
        guard let panel, panel.isVisible else { return }
        observation?.cancel()
        observation = nil
        loadTask?.cancel()
        panel.onResignKey = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if pageHadFocus { onReturnFocus?() }
    }

    private func present(in window: NSWindow, anchor: NSView) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = cardSize
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let margin = PageInfoStyle.shadowMargin
        var frame = NSRect(x: anchorRect.minX - margin - PageInfoStyle.rowInset,
                           y: anchorRect.minY - size.height - 2, width: size.width, height: size.height)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = max(frame.minY, screen.minY)
        }
        panel.appearance = window.effectiveAppearance
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.onResignKey = { [weak self] in self?.dismissForResign() }
        if !panel.isVisible { panel.orderFront(nil) }
        panel.makeKey()
        panel.makeFirstResponder(card)
    }

    private func makePanel() -> PageInfoPanel {
        let panel = PageInfoPanel()
        panel.contentView = card
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        return panel
    }

    /// Closing because another window took key status: remember a mouse-down
    /// on the omnibar button so its mouse-up does not reopen the bubble.
    private func dismissForResign() {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown { dismissedByMouseDown = event.eventNumber }
        close()
    }

    /// Rebuilds the current page, keeping keyboard focus on the same row.
    func render() {
        let focused = (panel?.firstResponder as? NSView)?.identifier
        let content = PageInfoPages(model: model, send: { [weak self] in self?.send($0) }).build()
        let size = card.setContent(content)
        let margin = PageInfoStyle.shadowMargin
        let full = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        cardSize = full
        if let panel, panel.isVisible, panel.frame.size != full {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - full.height, width: full.width, height: full.height), display: true)
        }
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

    /// Escape closes (Chrome); Up and Down move between rows like Tab.
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
