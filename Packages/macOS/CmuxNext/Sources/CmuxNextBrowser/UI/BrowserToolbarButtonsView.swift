public import AppKit

/// The trailing toolbar buttons (`BrowserToolbarButton`): design mode,
/// profile, theme, DevTools and More. Engine-neutral: the states come from
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
    /// Design mode and color scheme of the bound tab.
    public let modes = BrowserPageModes()
    /// 0 shows every button; 1 hides design mode and DevTools; 2 also
    /// profile and theme (`BrowserToolbarButton.collapseLevel`). More lists
    /// the hidden ones.
    public private(set) var collapse = 0

    /// The buttons hidden now (the More menu offers their actions).
    public var collapsedButtons: [BrowserToolbarButton] { BrowserToolbarButton.allCases.filter { $0.isCollapsed(at: collapse) } }

    private var buttons: [BrowserToolbarButton: ChromeIconButton] = [:]
    private var states: [BrowserToolbarButton: BrowserToolbarButtonState] = [:]
    private weak var tab: (any BrowserTab)?
    private var observation: ObservationLoop?
    private var pageURL: URL?

    public init() {
        super.init(frame: .zero)
        orientation = .horizontal
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.required, for: .horizontal)
        for button in BrowserToolbarButton.allCases {
            let view = ChromeIconButton(symbol: "circle", label: "", action: #selector(pressed(_:)), target: self, toolbar: true)
            view.setAccessibilityIdentifier(button.identifier)
            view.tag = BrowserToolbarButton.allCases.firstIndex(of: button) ?? 0
            buttons[button] = view
            addArrangedSubview(view)
        }
        render()
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

    /// The button's view, the anchor for its menu.
    public func button(_ button: BrowserToolbarButton) -> NSView? { buttons[button] }

    /// What `button` shows now (tests, `debug.extensions.toolbar`).
    public func state(_ button: BrowserToolbarButton) -> BrowserToolbarButtonState? { states[button] }

    /// Pops `menu` up under `button` (under More when the button is
    /// collapsed, at the top of the view when the toolbar is hidden) on the
    /// next run-loop turn, so a CLI or palette caller returns first.
    public func present(_ menu: NSMenu, from button: BrowserToolbarButton) {
        refresh()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let anchor = self.anchor(for: button) else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : -4), in: anchor)
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
        for (button, view) in buttons { view.isHidden = button.isCollapsed(at: level) }
    }

    /// Width of the buttons shown at collapse `level`.
    func width(collapse level: Int) -> CGFloat {
        let count = BrowserToolbarButton.allCases.filter { !$0.isCollapsed(at: level) }.count
        return CGFloat(count) * OmnibarStyle.buttonSize + CGFloat(max(0, count - 1)) * BrowserMetrics.buttonSpacing
    }

    @objc private func pressed(_ sender: NSButton) {
        guard BrowserToolbarButton.allCases.indices.contains(sender.tag) else { return }
        refresh()
        onPress?(BrowserToolbarButton.allCases[sender.tag])
    }

    private func render() {
        let facts = currentFacts()
        for button in BrowserToolbarButton.allCases {
            let state = BrowserToolbarPolicy.state(button, facts, shortcut: shortcutHint?(button))
            states[button] = state
            guard let view = buttons[button] else { continue }
            view.setSymbol(state.symbol, label: state.label)
            view.isEnabled = state.isEnabled
            view.isOn = state.isActive
        }
    }

    private func currentFacts() -> BrowserToolbarFacts {
        guard let tab else { return BrowserToolbarFacts(engine: .webkit, hostsDevTools: false, profileName: profileName) }
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
            designMode: modes.designMode, colorScheme: modes.colorScheme, profileName: profileName
        )
    }
}
