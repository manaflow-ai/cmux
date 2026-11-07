public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The trailing toolbar buttons (`BrowserToolbarButton`): media hub, zoom level, Favorites,
/// Downloads, design mode, profile, theme, DevTools and More. The toolbar page draws them
/// (`buttons` in its state); this model resolves their states (`BrowserToolbarPolicy` over the
/// bound tab), reports a press (`onPress`; the App runs the button's catalog action) and opens
/// menus and popups at the button the page reported. Holds no key handling: shortcuts go through
/// the action registry.
@MainActor
public final class BrowserToolbarButtons {
    /// A button was pressed. The App maps it to its action.
    public var onPress: ((BrowserToolbarButton) -> Void)?
    /// The display text of an action's shortcut, for the tooltips.
    public var shortcutHint: ((BrowserToolbarButton) -> String?)? { didSet { rebind() } }
    /// The tab's browser profile name, for the profile button's tooltip.
    public var profileName: String? { didSet { render() } }
    /// The App's downloads, read while rendering so an observable list redraws the button as
    /// downloads start and end. Set after `bind`, so it re-arms the observation to track the list.
    public var downloads: (() -> BrowserToolbarDownloads)? { didSet { rebind() } }
    /// Every tab's media, read the same way.
    public var media: (() -> BrowserToolbarMedia)? { didSet { rebind() } }
    /// The pinned buttons' ids (`browser.toolbarButtons`), read the same way, so a pin from any
    /// window or from cmux.json reaches every toolbar.
    public var pins: (() -> [String])? { didSet { rebind() } }
    /// The media hub's cards, kept between opens.
    public let mediaRows = BrowserMediaRows()
    /// Design mode and color scheme of the bound tab.
    public private(set) var modes = BrowserPageModes()
    /// The level the page collapsed the row to: 0 shows every button; 1 hides design mode and
    /// DevTools; 2 also media, zoom, Favorites, Downloads, profile and theme. More lists the hidden ones.
    public private(set) var collapse = 0
    /// The buttons a person pinned (`browser.toolbarButtons`); the others are rows of the More menu.
    public var pinned: Set<BrowserToolbarButton> = [] {
        didSet { if pinned != oldValue { onChange?() } }
    }

    /// The buttons not in the toolbar now, unpinned or collapsed (the More menu offers their actions).
    public var menuButtons: [BrowserToolbarButton] {
        BrowserToolbarButton.pinnable.filter { !pinned.contains($0) || $0.isCollapsed(at: collapse) }
    }

    /// The toolbar left the screen (its pane parked it, the tab closed or moved): a popup open
    /// under one of its buttons closes. Set by the popup.
    public var onDetach: (() -> Void)?
    /// The row whose page draws the buttons (the anchor of last resort for a popup).
    public internal(set) weak var toolbarView: BrowserToolbarWebView?
    /// What the page draws changed: the chrome pushes it.
    var onChange: (() -> Void)?
    /// Renders so far (tests: a tab switch renders the toolbar once).
    private(set) var renders = 0

    private var states: [BrowserToolbarButton: BrowserToolbarButtonState] = [:]
    private var pressed: Set<BrowserToolbarButton> = []
    private weak var tab: (any BrowserTab)?
    private var observation: ObservationLoop?
    private var pageURL: URL?
    /// The last facts rendered: zoom and Downloads show only on some.
    private var facts = BrowserToolbarFacts(engine: .webkit, hostsDevTools: false)
    private var batching = false
    private var batchedChange = false
    /// Sources set with no render (`batchSources(rendering: false)`): the next `bind` observes them, never skips.
    private var sourcesPending = false

    public init() {
        render()
    }

    /// Sets several sources (`shortcutHint`, `downloads`, `media`, `pins`) with one re-observation
    /// and render, or none when `rendering` is false (a `bind` follows and renders them).
    public func batchSources(rendering: Bool = true, _ set: () -> Void) {
        batching = true
        set()
        batching = false
        if batchedChange {
            batchedChange = false
            if rendering { rebind() } else { sourcesPending = true }
        }
    }

    /// Shows `tab`'s states. A new page (another tab, or the chrome's tab swapped) gets the chosen
    /// color scheme and starts with design mode off.
    func bind(_ tab: any BrowserTab, modes tabModes: BrowserPageModes? = nil) {
        // The page's attach binds the tab a tab switch bound already (with its modes): it already observes it.
        if tab === self.tab, tabModes == nil || tabModes === modes, observation != nil, !sourcesPending { return }
        if let tabModes, tabModes !== modes {
            // Another tab of the pane: its own modes, as it left them, and the document they were for.
            modes.pageURL = pageURL
            modes = tabModes
            self.tab = tab
            pageURL = tabModes.pageURL ?? tab.state.url
        } else if self.tab !== tab {
            self.tab = tab
            pageURL = tab.state.url
            modes.designMode = false
            if modes.colorScheme != .system { (tab as? any BrowserColorSchemeApplying)?.applyColorScheme(modes.colorScheme) }
        }
        observe()
    }

    private func observe() {
        sourcesPending = false
        observation?.cancel()
        observation = ObservationLoop { [weak self] in self?.render() }
    }

    /// An App closure changed after `bind`: observe again so its reads count.
    private func rebind() {
        guard !batching else { return batchedChange = true }
        guard tab != nil else { return render() }
        observe()
    }

    /// Reads the states again, WebKit's inspector visibility included (`WebKitInspectorWatch`
    /// misses an inspector hidden without a view or window change): on a press, a menu, and when
    /// the toolbar is shown.
    public func refresh() {
        (tab as? WebKitTab)?.inspectorWatch.refresh()
        render()
    }

    /// The toolbar left the screen or hid: popups under its buttons close.
    func detached() { onDetach?() }

    /// Shows `menu` at a point of a view and returns when it closes (`NSMenu.popUp`). Tests
    /// replace it: a real menu runs its own tracking loop.
    var popUpMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// The button's anchor (the page's rect for it), for its menu; nil while it is not shown.
    public func button(_ button: BrowserToolbarButton) -> NSView? { toolbarView?.anchor("button:\(button.rawValue)") }

    /// Whether `button` has anything to show, pinned or not, collapsed or not (the media hub only
    /// while a tab has media).
    public func hasContent(_ button: BrowserToolbarButton) -> Bool { button.hasContent(facts) }

    /// What `button` shows now (tests, `debug.extensions.toolbar`).
    public func state(_ button: BrowserToolbarButton) -> BrowserToolbarButtonState? { states[button] }

    /// Pops `menu` up under `button` (under More when the button is collapsed, at the row when the
    /// toolbar is hidden) on the next run-loop turn, so a CLI or palette caller returns first.
    /// `themed` opens it in the toolbar's light or dark look (`NSMenu.themeRows(in:)`).
    public func present(_ menu: NSMenu, from button: BrowserToolbarButton, themed: Bool = false) {
        refresh()
        if themed, let toolbarView { menu.themeRows(in: toolbarView.themeScope.fullStrength) }
        MainRunLoopBlock.perform { [weak self] in
            guard let self, let anchor = self.anchor(for: button) else { return }
            // Pressed while the menu is open, normal again when it closes (Chrome).
            let shown = self.shownButton(for: button)
            if let shown { self.setPressed(shown, true) }
            self.popUpMenu(menu, CmuxPopoverAnchor.menuPoint(for: menu, in: anchor, gap: 4), anchor)
            if let shown { self.setPressed(shown, false) }
        }
    }

    /// The view a popup of `button` opens under: the button, More when it is collapsed, the row
    /// when the toolbar is hidden.
    public func popupAnchor(for button: BrowserToolbarButton) -> NSView? { anchor(for: button) }

    /// Draws `anchor`'s button pressed while its popup is open, as its menu does (Chrome).
    public func setPopupOpen(_ open: Bool, anchor: NSView) {
        guard let key = (anchor as? ToolbarAnchorView)?.key, key.hasPrefix("button:"),
              let button = BrowserToolbarButton(rawValue: String(key.dropFirst("button:".count))) else { return }
        setPressed(button, open)
    }

    func anchor(for button: BrowserToolbarButton) -> NSView? {
        shownButton(for: button).flatMap(self.button) ?? toolbarView
    }

    /// `button` when the page shows it, else More when that shows.
    private func shownButton(for button: BrowserToolbarButton) -> BrowserToolbarButton? {
        [button, .overflow].first { self.button($0)?.window != nil }
    }

    private func setPressed(_ button: BrowserToolbarButton, _ on: Bool) {
        let changed = on ? pressed.insert(button).inserted : pressed.remove(button) != nil
        if changed { onChange?() }
    }

    /// The page collapsed the row to `level` (its `layout` report).
    func setCollapse(_ level: Int) {
        guard level != collapse else { return }
        collapse = level
    }

    /// A press on the page's button `button`.
    func press(_ button: BrowserToolbarButton) {
        refresh()
        onPress?(button)
    }

    /// The buttons that have something to show (pinned, with content, More always), in catalog
    /// order, as the page draws them (`WireToolbarButton`). The page hides them by collapse level.
    var wire: [[String: Any]] {
        BrowserToolbarButton.allCases.compactMap { button in
            guard button.isShown(at: 0, facts, pinned: pinned), let state = states[button] else { return nil }
            return state.wire(button, pressed: pressed.contains(button))
        }
    }

    private func render() {
        renders += 1
        if let pins {
            let next = Set(pins().compactMap(BrowserToolbarButton.init(rawValue:)))
            if next != pinned { pinned = next }
        }
        let facts = currentFacts()
        var changed = facts != self.facts
        self.facts = facts
        for button in BrowserToolbarButton.allCases {
            let state = BrowserToolbarPolicy.state(button, facts, shortcut: shortcutHint?(button))
            // Most tab state events (title, progress, address) change no button.
            guard states[button] != state else { continue }
            states[button] = state
            changed = true
        }
        if changed { onChange?() }
    }

    private func currentFacts() -> BrowserToolbarFacts {
        let downloads = downloads?() ?? BrowserToolbarDownloads()
        let media = media?() ?? BrowserToolbarMedia()
        guard let tab else {
            return BrowserToolbarFacts(engine: .webkit, hostsDevTools: false, profileName: profileName, downloads: downloads, media: media)
        }
        let url = tab.state.url
        if url != pageURL {
            pageURL = url
            if modes.designMode { modes.designMode = false }
        }
        let hosting = tab as? any BrowserDevToolsHosting
        let webKit = tab as? WebKitTab
        return BrowserToolbarFacts(
            engine: tab.engineKind, hostsDevTools: hosting != nil || webKit != nil,
            devToolsOpen: hosting?.devTools.isOpen ?? webKit?.isInspectorVisible ?? false,
            designMode: modes.designMode, colorScheme: modes.colorScheme, profileName: profileName, zoom: tab.state.zoom,
            downloads: downloads, media: media
        )
    }

    /// `menu` (More) with a separator and Show in Toolbar at its end (`showInToolbarItem`); `pin`
    /// is whether the rows are enabled and the toggle by button id.
    public func addingShowInToolbar(to menu: NSMenu, _ pin: (enabled: Bool, toggle: (String) -> Void)) -> NSMenu {
        menu.addItem(.separator())
        menu.addItem(showInToolbarItem(enabled: pin.enabled) { pin.toggle($0.rawValue) })
        return menu
    }

    /// The More menu's Show in Toolbar item: one checked row per pinnable button (`pinned`);
    /// choosing one calls `toggle`. Rows are disabled when `enabled` is false (a managed list).
    public func showInToolbarItem(enabled: Bool, toggle: @escaping (BrowserToolbarButton) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: BrowserToolbarButton.showInToolbarTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: BrowserToolbarButton.showInToolbarTitle)
        submenu.autoenablesItems = false
        for button in BrowserToolbarButton.pinnable {
            let trampoline = MenuTrampoline()
            trampoline.action = { toggle(button) }
            let row = NSMenuItem(title: button.pinTitle, action: #selector(MenuTrampoline.fire), keyEquivalent: "")
            row.target = trampoline
            row.representedObject = trampoline // the item keeps its target alive
            row.state = pinned.contains(button) ? .on : .off
            row.isEnabled = enabled
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }
}
