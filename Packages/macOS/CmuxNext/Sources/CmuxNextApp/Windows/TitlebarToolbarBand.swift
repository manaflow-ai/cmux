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
    /// A plain outline with a filled leading third: no row ticks, which blur
    /// to a smudge at 1x in `sidebar.left`.
    let sidebarToggle = TitlebarBandButton(symbol: "rectangle.leftthird.inset.filled")
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

/// An icon button of the toolbar band, in the same glyph family as the
/// sidebar's icon buttons next to it (TRAFFIC-LIGHTS-ALWAYS-AND-CLEAN-SIDEBAR-TOGGLE):
/// an SF Symbol at `smallIconSize`, the same weight, `textSecondary` at rest
/// and `textPrimary` with the shared `hoverFill` while hovered or pressed
/// (`ChromeHover`). The glyph is drawn on the device pixel grid, so its
/// strokes stay crisp at 1x and 2x.
final class TitlebarBandButton: NSButton {
    static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    /// The sidebar icon buttons' weight (spec visuals/components/sidebar.md).
    static let weight: NSFont.Weight = .semibold
    private let symbol: String
    /// Icon size, side and scale of the drawn glyph (redrawn when one changes).
    private var renderedKey: [CGFloat] = []
    private(set) lazy var hover = ChromeHover(self, behindContent: true)

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        renderSymbol()
        _ = hover
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        renderSymbol()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderSymbol()
    }

    /// The scale the glyph is drawn for: the window's, else the main screen's.
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func renderSymbol() {
        let size = Metrics.smallIconSize, side = Self.side, scale = backingScale
        guard renderedKey != [size, side, scale] else { return }
        renderedKey = [size, side, scale]
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: Self.weight)) else {
            image = nil
            return
        }
        let rect = Self.glyphRect(glyph.size, side: side, scale: scale)
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            glyph.draw(in: rect)
            return true
        }
        canvas.isTemplate = true
        image = canvas
    }

    /// Where a glyph of `size` sits in the button's `side` square: centered,
    /// its origin rounded to the device pixel grid at `scale` (pure). AppKit
    /// centers an odd-sized symbol on a half point, which blurs its strokes
    /// at 1x.
    static func glyphRect(_ size: CGSize, side: CGFloat, scale: CGFloat) -> CGRect {
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        return CGRect(x: snap((side - size.width) / 2), y: snap((side - size.height) / 2), width: size.width, height: size.height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
        }
        hover.refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { changeHover { $0.hovering = true } }
    override func mouseExited(with event: NSEvent) { changeHover { $0.hovering = false } }

    /// A button faded out under the pointer gets no exit event; it comes
    /// back without the fill.
    override func viewDidHide() {
        super.viewDidHide()
        changeHover { $0.hovering = false; $0.pressed = false }
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
