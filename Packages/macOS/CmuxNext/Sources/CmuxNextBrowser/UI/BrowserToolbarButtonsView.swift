public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The trailing toolbar buttons (`BrowserToolbarButton`): media hub, zoom level,
/// Favorites, Downloads, design mode, profile, theme, DevTools and More. Engine-neutral: the states come from
/// `BrowserToolbarPolicy` over the bound tab, and a press only reports the
/// button (`onPress`); the App runs the button's catalog action. Holds no
/// key handling: shortcuts go through the action registry.
public final class BrowserToolbarButtonsView: NSStackView {
    /// A button was pressed. The App maps it to its action.
    public var onPress: ((BrowserToolbarButton) -> Void)?
    /// The display text of an action's shortcut, for the tooltips.
    public var shortcutHint: ((BrowserToolbarButton) -> String?)? { didSet { render() } }
    /// The tab's browser profile name, for the profile button's tooltip.
    public var profileName: String? { didSet { render() } }
    /// The App's downloads, read while rendering so an observable list
    /// redraws the button as downloads start and end. Set after `bind`, so
    /// it re-arms the observation to track the list.
    public var downloads: (() -> BrowserToolbarDownloads)? { didSet { rebind() } }
    /// Every tab's media, read the same way.
    public var media: (() -> BrowserToolbarMedia)? { didSet { rebind() } }
    /// Design mode and color scheme of the bound tab.
    public let modes = BrowserPageModes()
    /// 0 shows every button; 1 hides design mode and DevTools; 2 also
    /// media, zoom, Favorites, Downloads, profile and theme (`BrowserToolbarButton.collapseLevel`).
    /// More lists the hidden ones.
    public private(set) var collapse = 0

    /// The buttons hidden now (the More menu offers their actions).
    public var collapsedButtons: [BrowserToolbarButton] { BrowserToolbarButton.allCases.filter { $0.isCollapsed(at: collapse) } }

    private var buttons: [BrowserToolbarButton: ChromeIconButton] = [:]
    private var states: [BrowserToolbarButton: BrowserToolbarButtonState] = [:]
    private weak var tab: (any BrowserTab)?
    private var observation: ObservationLoop?
    private var pageURL: URL?
    /// The last facts rendered: zoom and Downloads show only on some.
    private var facts = BrowserToolbarFacts(engine: .webkit, hostsDevTools: false)

    public init() {
        super.init(frame: .zero)
        orientation = .horizontal
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.required, for: .horizontal)
        for button in BrowserToolbarButton.allCases {
            let view = ChromeIconButton(icon: .placeholder, label: "", action: #selector(pressed(_:)), target: self, toolbar: true)
            view.setAccessibilityIdentifier(button.identifier)
            view.tag = BrowserToolbarButton.allCases.firstIndex(of: button) ?? 0
            buttons[button] = view
            addArrangedSubview(view)
        }
        render()
        applyVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `tab`'s states. A new page (another tab, or the chrome's tab
    /// swapped) gets the chosen color scheme and starts with design mode off.
    func bind(_ tab: any BrowserTab) {
        observation?.cancel()
        if self.tab !== tab {
            self.tab = tab
            pageURL = tab.state.url
            modes.designMode = false
            if modes.colorScheme != .system { (tab as? any BrowserColorSchemeApplying)?.applyColorScheme(modes.colorScheme) }
        }
        observation = ObservationLoop { [weak self] in self?.render() }
    }

    /// An App closure changed after `bind`: observe again so its reads count.
    private func rebind() {
        guard let tab else { return render() }
        bind(tab)
    }

    /// Reads the states again, WebKit's inspector visibility included
    /// (`WebKitInspectorWatch` misses an inspector hidden without a view or
    /// window change): on a press, a menu, and when the toolbar is shown.
    public func refresh() {
        (tab as? WebKitTab)?.inspectorWatch.refresh()
        render()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    /// Shown again after its pane parked it (another tab showed).
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        if window != nil { refresh() }
    }

    /// The button's view, the anchor for its menu.
    public func button(_ button: BrowserToolbarButton) -> NSView? { buttons[button] }

    /// Whether `button` has anything to show, collapsed or not (the media
    /// hub only while a tab has media).
    public func hasContent(_ button: BrowserToolbarButton) -> Bool { button.isShown(at: 0, facts) }

    /// What `button` shows now (tests, `debug.extensions.toolbar`).
    public func state(_ button: BrowserToolbarButton) -> BrowserToolbarButtonState? { states[button] }

    /// Pops `menu` up under `button` (under More when the button is
    /// collapsed, at the top of the view when the toolbar is hidden) on the
    /// next run-loop turn, so a CLI or palette caller returns first.
    public func present(_ menu: NSMenu, from button: BrowserToolbarButton) {
        refresh()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                guard let self, let anchor = self.anchor(for: button) else { return }
                menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: anchor, gap: 4), in: anchor)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func anchor(for button: BrowserToolbarButton) -> NSView? {
        let shown = [button, .overflow].compactMap { buttons[$0] }.first { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
        return shown ?? superview
    }

    /// Hides the buttons of collapse `level` and below (BrowserChromeView).
    func setCollapse(_ level: Int) {
        guard level != collapse else { return }
        collapse = level
        applyVisibility()
    }

    private func applyVisibility() {
        for (button, view) in buttons { view.isHidden = !button.isShown(at: collapse, facts) }
    }

    /// Width of the buttons shown at collapse `level`.
    func width(collapse level: Int) -> CGFloat {
        let count = BrowserToolbarButton.allCases.filter { $0.isShown(at: level, facts) }.count
        return CGFloat(count) * OmnibarStyle.buttonSize + CGFloat(max(0, count - 1)) * BrowserMetrics.buttonSpacing
    }

    @objc private func pressed(_ sender: NSButton) {
        guard BrowserToolbarButton.allCases.indices.contains(sender.tag) else { return }
        refresh()
        onPress?(BrowserToolbarButton.allCases[sender.tag])
    }

    private func render() {
        let facts = currentFacts()
        // Which buttons take room at all, whatever the collapse level:
        // leaving 100 % at level 2 may let level 0 fit again.
        let shown = { (facts: BrowserToolbarFacts) in BrowserToolbarButton.allCases.filter { $0.isShown(at: 0, facts) } }
        let relayout = shown(facts) != shown(self.facts)
        self.facts = facts
        if relayout { relayoutChrome() }
        for button in BrowserToolbarButton.allCases {
            let state = BrowserToolbarPolicy.state(button, facts, shortcut: shortcutHint?(button))
            // Most tab state events (title, progress, address) change no
            // button: leave those buttons untouched.
            guard states[button] != state else { continue }
            states[button] = state
            guard let view = buttons[button] else { continue }
            view.setIcon(state.icon, label: state.label)
            view.isEnabled = state.isEnabled
            view.isOn = state.isActive
        }
    }

    /// The zoom or Downloads button appeared or went: the chrome collapses the toolbar
    /// again for the new width (`BrowserChromeView.applyToolbarLayout`).
    private func relayoutChrome() {
        applyVisibility()
        var view = superview
        while let current = view, !(current is BrowserChromeView) { view = current.superview }
        view?.needsLayout = true
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
}
