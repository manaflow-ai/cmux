import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHistory
import Observation

/// The toolbar band in the window's top row, right of the traffic lights
/// (R68/R69, spec titlebar-area.md): the sidebar toggle first (it lives in
/// the window root, not in the sidebar that animates), then Back and
/// Forward. A strip under it starts its tabs after it
/// (`TitlebarAccessoryHosting`). With the sidebar hidden the band has 0
/// width and is clear, so only the traffic lights show (cx-uxdr, Lawrence
/// 2026-10-08), until the pointer is over the top-left corner
/// (`CollapsedBandReveal`, 2026-10-09); `presence` follows the larger of the
/// two on-screen widths, frame by frame (`WindowRootView.layout`).
final class TitlebarToolbarBand: NSView {
    let sidebarToggle = TitlebarBandButton(symbol: SidebarToggleIcon.currentCollapseSymbol)
    /// How much of the band shows: 1 with the sidebar shown, 0 with it
    /// hidden, in between while the sidebar's width (or the corner hover's
    /// `CollapsedBandReveal`) animates. The items close up toward the band's
    /// origin and fade with it. Fully collapsed, the band is clear and 0
    /// wide but never hidden: keyboard and VoiceOver reach its buttons with
    /// no hover, and keyboard focus on one opens the band.
    var presence: CGFloat = 1 {
        didSet {
            guard presence != oldValue else { return }
            alphaValue = presence
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
        sidebarToggle.customImage = SidebarToggleIcon.image(named:pointSize:) // its candidate glyphs
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggle)
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        backButton.menuProvider = { [weak self] in self?.historyMenu?(.back) }
        forwardButton.menuProvider = { [weak self] in self?.historyMenu?(.forward) }
        [sidebarToggle, backButton, forwardButton].forEach(addSubview)
        sidebarToggle.setAccessibilityIdentifier("cmux.titlebar.toggleSidebar")
        backButton.setAccessibilityIdentifier("cmux.titlebar.back")
        forwardButton.setAccessibilityIdentifier("cmux.titlebar.forward")
        followIcon()
    }

    /// Applies the Debug Settings / Debug menu icon choice live.
    private func followIcon() {
        iconObservation?.cancel()
        let store = iconStore
        // task-owner: the band (cancelled in deinit and on a store change); event-driven (Observation)
        iconObservation = Task { [weak self] in
            for await _ in ObservationStream({ SidebarToggleIcon.tunable.value(in: store) }) {
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
    func describeHistory(back: String, forward: String, backShortcut: String? = nil, forwardShortcut: String? = nil) {
        backButton.setAccessibilityLabel(back)
        backButton.themedToolTip = back
        backButton.themedToolTipShortcut = backShortcut
        forwardButton.setAccessibilityLabel(forward)
        forwardButton.themedToolTip = forward
        forwardButton.themedToolTipShortcut = forwardShortcut
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

    /// The band's full width: the toggle, a group gap (`space3`, as after
    /// the traffic lights), then Back and Forward `space1` apart.
    static var width: CGFloat { TitlebarBandButton.side * 3 + Metrics.space3 + Metrics.space1 }

    /// Each item is `presence` of its width, and the gaps close with it, so
    /// the band reaches 0 width with no jump.
    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        let width = side * presence
        var x: CGFloat = 0
        for (button, gap) in [(sidebarToggle, Metrics.space3), (backButton, Metrics.space1), (forwardButton, 0)] {
            button.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: width, height: side)
            x += (side + gap) * presence
        }
    }

    /// Names the toggle with its action title and bound key.
    func describeToggle(title: String, shortcut: String?) {
        sidebarToggle.setAccessibilityLabel(title)
        sidebarToggle.themedToolTip = title
        sidebarToggle.themedToolTipShortcut = shortcut
    }

    private var descriptionObservation: Task<Void, Never>?

    /// Keeps the toggle's title and key current: a rebind (cmux.json,
    /// Settings) shows at once (R68 follow-up).
    func followToggleDescription(title: @escaping @MainActor () -> String, shortcut: @escaping @MainActor () -> String?) {
        descriptionObservation?.cancel()
        // task-owner: the band (cancelled in deinit); event-driven (Observation)
        descriptionObservation = Task { [weak self] in
            for await (title, shortcut) in ObservationStream({ (title(), shortcut()) }) {
                self?.describeToggle(title: title, shortcut: shortcut)
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        descriptionObservation?.cancel()
        iconObservation?.cancel()
    }
}
