import AppKit
import CmuxNextDesign
import CmuxNextHistory
import Observation

/// The toolbar band in the window's top row, right of the traffic lights
/// (R68/R69, spec titlebar-area.md): the sidebar toggle first (it lives in
/// the window root, not in the sidebar that animates), then Back and
/// Forward. A strip under it starts its tabs after it
/// (`TitlebarAccessoryHosting`). With the sidebar hidden the band has 0
/// width and is clear, so only the traffic lights show (cx-uxdr, Lawrence
/// 2026-10-08); `presence` follows the sidebar's on-screen width, frame by
/// frame (`WindowRootView.layout`).
final class TitlebarToolbarBand: NSView {
    let sidebarToggle = TitlebarBandButton(symbol: SidebarToggleIcon.currentCollapseSymbol)
    /// The toggle's glyph while the sidebar shows (the default icon).
    static var collapseSymbol: String { SidebarToggleIcon.currentCollapseSymbol }
    /// The toggle's glyph while the sidebar is hidden (the default icon).
    static var expandSymbol: String { SidebarToggleIcon.currentExpandSymbol }
    /// How much of the band shows: 1 with the sidebar shown, 0 with it
    /// hidden, in between while the sidebar's width animates. The items
    /// close up toward the band's origin and fade with it. Fully collapsed,
    /// the band is hidden: its 0-width buttons leave the key view loop and
    /// the accessibility tree, and come back as soon as it grows.
    var presence: CGFloat = 1 {
        didSet {
            guard presence != oldValue else { return }
            alphaValue = presence
            isHidden = presence == 0
            needsLayout = true
        }
    }
    /// Where the icon choice is read (tests pass their own store).
    var iconStore: TunableStore = .shared {
        didSet { followIcon() }
    }
    /// The sidebar state the toggle's glyph shows.
    private(set) var showsSidebarHidden = false
    private var iconObservation: Task<Void, Never>?
    /// Back and Forward through the location trail (R69).
    let backButton = TitlebarBandButton(symbol: "chevron.left")
    let forwardButton = TitlebarBandButton(symbol: "chevron.right")
    /// Runs the toggle's action (the registry's `toggleSidebar`).
    var onToggleSidebar: (() -> Void)?
    /// Runs Back or Forward (`focusHistoryBack` / `focusHistoryForward`).
    var onHistory: ((LocationTrailDirection) -> Void)?
    /// The window's LocationTrailService observer token.
    var historyObserver: Int?
    /// The list a right-click or long press shows (`history.goTo` per row).
    var historyMenu: ((LocationTrailDirection) -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggle)
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        backButton.menuProvider = { [weak self] in self?.historyMenu?(.back) }
        forwardButton.menuProvider = { [weak self] in self?.historyMenu?(.forward) }
        [sidebarToggle, backButton, forwardButton].forEach(addSubview)
        followIcon()
    }

    /// Applies the Debug Settings / Debug menu icon choice live.
    private func followIcon() {
        iconObservation?.cancel()
        let store = iconStore
        // task-owner: the band (cancelled in deinit and on a store change); event-driven (Observation)
        iconObservation = Task { [weak self] in
            for await _ in Observations({ SidebarToggleIcon.tunable.value(in: store) }) {
                guard let self else { return }
                showSidebarState(hidden: showsSidebarHidden)
            }
        }
    }

    @objc func goBack() { onHistory?(.back) }
    @objc func goForward() { onHistory?(.forward) }

    /// The Back or Forward button.
    func historyButton(_ direction: LocationTrailDirection) -> TitlebarBandButton {
        direction == .back ? backButton : forwardButton
    }

    /// Back and Forward are enabled only when the trail has somewhere to go.
    func setHistoryEnabled(back: Bool, forward: Bool) {
        backButton.isEnabled = back
        forwardButton.isEnabled = forward
    }

    /// Names Back and Forward with their actions' titles and keys.
    func describeHistory(back: String, forward: String) {
        backButton.setAccessibilityLabel(back)
        backButton.toolTip = back
        forwardButton.setAccessibilityLabel(forward)
        forwardButton.toolTip = forward
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every click toggles, mid-animation too: the button never moves, so
    /// there is no hit-test gap, and the sidebar's width animation
    /// retargets from what is on screen.
    @objc func toggle() { onToggleSidebar?() }

    /// The toggle's glyph follows the sidebar and the chosen icon
    /// (`SidebarToggleIcon`): with the default, collapse-left while it
    /// shows, the sidebar glyph while it is hidden (Leo, T3 Code ref).
    func showSidebarState(hidden: Bool) {
        showsSidebarHidden = hidden
        sidebarToggle.symbol = SidebarToggleIcon.tunable.value(in: iconStore).symbol(sidebarHidden: hidden)
    }

    /// The band's full width for its items: the toggle first, then Back
    /// and Forward.
    static var width: CGFloat { TitlebarBandButton.side * 3 + Metrics.space1 * 2 }

    /// Each item is `presence` of its width, and the gaps close with it, so
    /// the band reaches 0 width with no jump.
    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        let width = side * presence
        var x: CGFloat = 0
        for button in [sidebarToggle, backButton, forwardButton] {
            button.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: width, height: side)
            x += (side + Metrics.space1) * presence
        }
    }

    /// Names the toggle with its action title and bound key.
    func describeToggle(title: String, shortcut: String?) {
        sidebarToggle.setAccessibilityLabel(title)
        sidebarToggle.toolTip = shortcut.map { "\(title) (\($0))" } ?? title
    }

    private var descriptionObservation: Task<Void, Never>?

    /// Keeps the toggle's title and key current: a rebind (cmux.json,
    /// Settings) shows at once (R68 follow-up).
    func followToggleDescription(title: @escaping @MainActor () -> String, shortcut: @escaping @MainActor () -> String?) {
        descriptionObservation?.cancel()
        // task-owner: the band (cancelled in deinit); event-driven (Observation)
        descriptionObservation = Task { [weak self] in
            for await (title, shortcut) in Observations({ (title(), shortcut()) }) {
                self?.describeToggle(title: title, shortcut: shortcut)
            }
        }
    }

    isolated deinit {
        descriptionObservation?.cancel()
        iconObservation?.cancel()
    }
}

/// An icon button of the toolbar band: the chrome's hover and pressed look.
final class TitlebarBandButton: NSButton {
    static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    /// The SF Symbol it draws, or a custom glyph name
    /// (`SidebarToggleIcon.image(named:pointSize:)`).
    var symbol: String {
        didSet { if symbol != oldValue { renderedIconSize = 0; renderSymbol() } }
    }
    private var renderedIconSize: CGFloat = 0
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// Set once `hover` follows the pointer (not during NSButton's init).
    private var followsPointer = false

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        // A collapsing band narrows its items: the glyph scales down with them.
        imageScaling = .scaleProportionallyDown
        renderSymbol()
        contentTintColor = performWithTheme { Palette.textSecondary }
        // Hover follows the pointer and the button's frame (cx-3wu5): a band
        // that collapses or hides under a still pointer clears it.
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled ?? false })
        followsPointer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Disabled under a still pointer (Back with no history left): hover
    /// follows at once (cx-3wu5).
    override var isEnabled: Bool {
        didSet { if followsPointer, isEnabled != oldValue { hover.pointer?.refresh() } }
    }

    override func layout() {
        super.layout()
        renderSymbol()
    }

    private func renderSymbol() {
        let size = Metrics.smallIconSize
        guard size != renderedIconSize else { return }
        renderedIconSize = size
        image = SidebarToggleIcon.image(named: symbol, pointSize: size)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// A right-click or long-press menu (Back / Forward lists).
    var menuProvider: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// A long press shows the menu like a browser's Back button; a click runs.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard menuProvider != nil, let window else { return super.mouseDown(with: event) }
        let deadline = Date().addingTimeInterval(NSEvent.doubleClickInterval)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { sendAction(action, to: target); return }
        }
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: self, gap: Metrics.space1), in: self)
        }
    }
}
