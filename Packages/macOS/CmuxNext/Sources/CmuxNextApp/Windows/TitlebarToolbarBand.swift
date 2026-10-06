import AppKit
import CmuxNextDesign
import CmuxNextHistory
import Observation

/// The toolbar band in the window's top row, right of the traffic lights
/// (R68/R69, spec titlebar-area.md): the sidebar toggle first, at a fixed
/// frame that never moves with the sidebar (it lives in the window root,
/// not in the sidebar that animates), then the band's other items. A
/// strip under it starts its tabs after it (`TitlebarAccessoryHosting`).
final class TitlebarToolbarBand: NSView {
    let sidebarToggle = TitlebarBandButton(symbol: "sidebar.left")
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

    /// The band's width for its items: the toggle first (its frame is the
    /// band's origin and never moves), then Back and Forward.
    static var width: CGFloat { TitlebarBandButton.side * 3 + Metrics.space1 * 2 }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        var x: CGFloat = 0
        for button in [sidebarToggle, backButton, forwardButton] {
            button.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
            x += side + Metrics.space1
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
    }
}

/// An icon button of the toolbar band: the chrome's hover and pressed look.
final class TitlebarBandButton: NSButton {
    static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    private(set) lazy var hover = ChromeHover(self, behindContent: true)

    init(symbol: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular))
        contentTintColor = performWithTheme { Palette.textSecondary }
        _ = hover
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A right-click or long-press menu (Back / Forward lists).
    var menuProvider: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// A long press shows the menu like a browser's Back button; a click runs.
    override func mouseDown(with event: NSEvent) {
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
