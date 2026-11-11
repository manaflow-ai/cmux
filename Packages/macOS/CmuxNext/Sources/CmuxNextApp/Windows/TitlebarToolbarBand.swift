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
    let sidebarToggle = TitlebarBandButton(symbol: SidebarToggleIcon.panel.symbol(sidebarHidden: false))
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
    /// Where the sliding glyph's bar is (`SidebarToggleIcon.slides`): 0 at its sidebar-shown form, 1 at its hidden form.
    private var glyphProgress: Double = 0
    /// The leg the bar slides on, from and to a progress.
    private var glyphLeg = (from: 0.0, to: 0.0)
    /// Slides the bar with the sidebar's width, on the same clock and for the same time, so the two move as one.
    private(set) lazy var glyphMotion = TimedProgress { [weak self] progress in self?.stepGlyph(progress) }
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
        TitlebarBandButton.styleTopRow(toggle: sidebarToggle, back: backButton, forward: forwardButton) // one glyph height
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggle)
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        backButton.menuProvider = { [weak self] in self?.historyMenu?(.back) }
        forwardButton.menuProvider = { [weak self] in self?.historyMenu?(.forward) }
        // A dimmed arrow (nowhere to go) still lists Recently Closed and Show Full History.
        backButton.opensMenuWhenDisabled = true
        forwardButton.opensMenuWhenDisabled = true
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

    /// Back and Forward click only when the trail has somewhere to go; their right-click list
    /// opens either way (`opensMenuWhenDisabled`).
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
    /// (`SidebarToggleIcon`). The default panel's bar slides from one form to
    /// the other as the sidebar opens or closes (Leo 2026-11-09: "with teh
    /// animation too on click"); a slide under way turns around from where it
    /// shows. The other icons swap at once.
    func showSidebarState(hidden: Bool) {
        let changed = hidden != showsSidebarHidden
        showsSidebarHidden = hidden
        let icon = SidebarToggleIcon.tunable.value(in: iconStore)
        let target: Double = hidden ? 1 : 0
        guard icon.slides, changed || glyphMotion.isRunning else {
            glyphMotion.stop()
            glyphProgress = target
            sidebarToggle.symbol = icon.symbol(sidebarHidden: hidden)
            return
        }
        guard changed else { return }
        glyphLeg = (glyphProgress, target)
        let duration = Motion.sidebar.canAnimate(in: self) ? Motion.sidebar.duration(hidden ? .disappear : .appear, in: window) : 0
        glyphMotion.run(duration: duration, in: self, trace: "sidebar.toggleGlyph")
    }

    /// One frame of the bar's slide.
    private func stepGlyph(_ progress: Double) {
        glyphProgress = glyphLeg.from + (glyphLeg.to - glyphLeg.from) * progress
        sidebarToggle.symbol = SidebarToggleIcon.slideSymbol(progress: glyphProgress)
    }

    /// The band's full width: the toggle, Back and Forward one gap apart, each the +'s size (`TopRowSpacing`).
    static var width: CGFloat { TopRowSpacing.bandWidth }

    /// Each item is `presence` of its width, and the gaps close with it, so
    /// the band reaches 0 width with no jump.
    override func layout() {
        super.layout()
        let side = TopRowSpacing.buttonSide
        let width = side * presence
        var x: CGFloat = 0
        for (button, gap) in [(sidebarToggle, TopRowSpacing.toggleGap), (backButton, TopRowSpacing.groupGap), (forwardButton, 0)] {
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
