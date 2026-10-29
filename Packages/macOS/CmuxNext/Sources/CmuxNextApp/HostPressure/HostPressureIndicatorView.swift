import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHostPressure
import CmuxNextWakeups

/// The window's host pressure indicator in the top row, after the toolbar band
/// and the incognito badge (`WindowRootView.hostPressureIndicator`; never the
/// sidebar). Hidden while the host is normal; at warning and critical a still
/// glyph in the theme's attention color (no pulse, no animation), whose click
/// opens the popover. At critical, with the Debug Settings toggle
/// `hostPressure.banner` on (off by default), it also shows a banner (an
/// untilClosed toast) whose Show Details opens the popover; closing it keeps it
/// closed in that window until the next critical spell. The banner has no timer of its
/// own: it follows the same level observation, and ends with it.
///
/// Off by default (cmux#22662): it subscribes to the app's `HostPressureService`
/// only while `HostPressureSampling.samples` holds (the feature `hostPressure`, resolved
/// once per launch, is on and its window can be seen). Stop condition: the window's node in
/// the visibility tree going hidden or occluded (the window minimized or fully occluded, cmux
/// hidden, the displays asleep), or the window closing, unsubscribes it, and the service stops
/// the monitor and its one 15 s timer when no window is subscribed. Cleanup: leaving the window
/// cancels the node, close and forced-level subscriptions, and leaving sampling the level
/// observation; each also ends when released with the view, from any thread
/// (`HostPressureSubscription` and `HostPressureBanner` end themselves the same way). While the
/// feature is off it never creates the service at all.
final class HostPressureIndicatorView: NSView {
    static let identifier = "cmux.titlebar.hostPressure"
    let button = TitlebarBandButton(symbol: HostPressureIndicatorView.symbol(.warning, style: .gauge))
    /// The load against its limit beside the glyph (`HostPressureIndicatorStyle.load`).
    let loadLabel = ThemedLabel(labelWithString: "")
    private var style = HostPressureIndicatorStyle.gauge
    private var banner: HostPressureBanner?
    /// The critical spell whose banner this window's person closed (or opened the details of).
    private var closedSpell: Int?
    private let services: AppServices
    private let store: TunableStore
    private let mainWork: MainWorkScheduler
    /// A window's node in the visibility tree and its notices (tests pass their own).
    private let nodeOf: @MainActor (NSWindow) -> VisibilityNode
    private let eventsOf: @MainActor (NSWindow) -> WindowEvents
    private let makeService: @MainActor () -> HostPressureService
    private let toasts: CmuxToastCenter
    /// Called when the indicator shows, hides or changes width: the owner places it again.
    private let onVisibilityChange: () -> Void
    private var subscription: HostPressureSubscription?
    private var service: HostPressureService? { subscription?.service }
    /// While in a window: its node's flips, its close and the Debug forced level.
    private var windowWatch: VisibilitySubscription?
    private var closeWatch: EventSubscription?
    private var forceWatch: ServiceObservation<HostPressureForce>?
    /// What the glyph and the banner show, while it samples.
    private typealias LevelFacts = (level: HostPressureLevel, verdict: HostBudgetVerdict?, style: HostPressureIndicatorStyle,
                                    banner: Bool, spell: Int)
    private var levelWatch: ServiceObservation<LevelFacts>?
    private lazy var popover: HostPressurePopover = makePopover()
    private(set) var level = HostPressureLevel.normal
    /// Whether it is subscribed to the service now (tests read it).
    var isSampling: Bool { service != nil }

    /// `store`, `mainWork`, `nodeOf`, `eventsOf`, `service` and `toasts` are for tests; the app passes none.
    init(services: AppServices, store: TunableStore = .shared, mainWork: MainWorkScheduler? = nil,
         nodeOf: @escaping @MainActor (NSWindow) -> VisibilityNode = { WindowVisibilitySource.of($0).node },
         eventsOf: @escaping @MainActor (NSWindow) -> WindowEvents = { WindowEvents.of($0) },
         service: (@MainActor () -> HostPressureService)? = nil, toasts: CmuxToastCenter = .shared,
         onVisibilityChange: @escaping () -> Void) {
        self.services = services
        self.store = store
        self.mainWork = mainWork ?? services.mainWork
        self.nodeOf = nodeOf
        self.eventsOf = eventsOf
        self.toasts = toasts
        self.makeService = service ?? {
            HostPressureService.shared(acpmux: QuitAgents.environment(services),
                                       memoryPressure: services.memoryPressure.hostPressureSubscription,
                                       mainWork: services.mainWork, work: services.work, appEvents: services.appEvents)
        }
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
        isHidden = true
        button.target = self
        button.action = #selector(togglePopover)
        button.setAccessibilityIdentifier(Self.identifier)
        loadLabel.font = Typography.caption
        loadLabel.ink = .secondary
        loadLabel.isHidden = true
        addSubview(button)
        addSubview(loadLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ level: HostPressureLevel, style: HostPressureIndicatorStyle) -> String {
        level == .critical || style == .triangle ? "exclamationmark.triangle" : "gauge.with.dots.needle.67percent"
    }

    /// The glyph's square, plus the load label after it in the `load` style.
    var width: CGFloat {
        TitlebarBandButton.side + (loadLabel.isHidden ? 0 : Metrics.space1 + ceil(loadLabel.intrinsicContentSize.width))
    }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        button.frame = CGRect(x: 0, y: 0, width: side, height: bounds.height)
        let label = loadLabel.intrinsicContentSize
        // The text starts `space1` after the glyph; the frame adds the label's padding around it
        // (a frame the size of the text alone clipped the last digit).
        loadLabel.frame = loadLabel.frame(forAlignmentRect: CGRect(x: side + Metrics.space1, y: ((bounds.height - label.height) / 2).rounded(),
                                                                   width: ceil(label.width), height: label.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        reconcile()
    }

    // visibility-walk-allow: the body is one tint assignment, a color set like a layer color's; deferring it to the window's node would leave a forced level's capture in an occluded window with the old appearance's tint
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// The gate's inputs now: the feature and whether the window can be seen (its node is visible). A forced level
    /// (Debug Settings only, for captures) counts as seen while the indicator is in a window: capture minis run
    /// windows the occlusion state calls hidden. The 15 s read then runs while the level stays forced; Off restores
    /// the window gate, and leaving the window still stops it.
    var sampling: HostPressureSampling {
        let forced = HostPressureTunables.force.value(in: store) != .off && window != nil
        return HostPressureSampling(enabled: services.features.isEnabled(.hostPressure),
                                    windowVisible: forced || window.map { nodeOf($0).isVisible } == true)
    }

    /// Subscribes while `sampling.samples`, else unsubscribes (idempotent).
    func reconcile() {
        sampling.samples ? join() : leave()
    }

    /// While in a window: the window's node (occlusion, minimizing, Hide cmux and sleeping displays already reach it
    /// through `WindowVisibilitySource` and `AppVisibilitySource`: no notice of its own), the window's close and the
    /// Debug forced level. A window change, willClose and the view's release end them.
    private func observeWindow() {
        stopWatching()
        guard let window else { return }
        windowWatch = nodeOf(window).subscribe(owner: "HostPressureIndicator.window") { [weak self] _ in self?.reconcile() }
        closeWatch = eventsOf(window).subscribe(NSWindow.willCloseNotification, owner: "HostPressureIndicator.close") { [weak self] in
            self?.leave()
            self?.stopWatching()
        }
        let store = store
        // A service observation: the forced level starts or stops the app's monitor as well as show the glyph.
        forceWatch = ServiceObservation(.visible, owner: "HostPressureIndicator.force", on: mainWork) {
            HostPressureTunables.force.value(in: store)
        } apply: { [weak self] _ in
            self?.reconcile()
        }
    }

    private func stopWatching() {
        windowWatch?.cancel()
        windowWatch = nil
        closeWatch?.cancel()
        closeWatch = nil
        forceWatch?.cancel()
        forceWatch = nil
    }

    private func join() {
        guard subscription == nil else { return }
        let service = makeService()
        subscription = HostPressureSubscription(service)
        let store = store
        // It exists only while this window samples (seen, or a forced level in a window), which is its gate: a node of
        // its own would stop the forced level a capture shows in an occluded window.
        levelWatch = ServiceObservation(.visible, owner: "HostPressureIndicator.level", on: mainWork) { () -> LevelFacts in
            (level: service.level, verdict: service.verdict, style: HostPressureTunables.style.value(in: store),
             banner: HostPressureTunables.banner.value(in: store), spell: service.criticalSpell)
        } apply: { [weak self] facts in
            guard let self else { return }
            style = facts.style
            show(level: facts.level, verdict: facts.verdict)
            showBanner(facts.banner && facts.level == .critical && closedSpell != facts.spell, verdict: facts.verdict, spell: facts.spell)
        }
    }

    private func leave() {
        guard let subscription else { return }
        levelWatch?.cancel()
        levelWatch = nil
        subscription.cancel()
        self.subscription = nil
        show(level: .normal, verdict: nil)
        showBanner(false, verdict: nil)
    }

    private func show(level: HostPressureLevel, verdict: HostBudgetVerdict?) {
        let (wasHidden, wasLevel, oldWidth) = (isHidden, self.level, width)
        self.level = level
        isHidden = level == .normal
        button.symbol = Self.symbol(level, style: style)
        loadLabel.isHidden = style != .load || verdict?.load1 == nil
        loadLabel.stringValue = verdict.map(Self.loadText) ?? ""
        let title = level == .critical ? HostPressureStrings.criticalTitle : HostPressureStrings.warningTitle
        button.setAccessibilityLabel(title)
        button.themedToolTip = title
        applyTint()
        if level == .normal {
            // The popover opens only above normal, so it is made (lazily) and shown only then.
            if wasLevel != .normal { popover.close() }
        } else {
            popover.content.update(level: level, verdict: verdict, canStop: service?.isForced == false)
        }
        // The owner (the window's root) lays the top row out again; the indicator never invalidates it.
        if wasHidden != isHidden || oldWidth != width { onVisibilityChange() }
    }

    /// "9.6 / 12": the 1-minute load against the budget's limit.
    static func loadText(_ verdict: HostBudgetVerdict) -> String {
        let load = verdict.load1.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"
        return "\(load) / \(verdict.loadLimit.formatted(.number.precision(.fractionLength(0 ... 1))))"
    }

    /// The critical banner: shown once per critical spell, ended when the level falls, the toggle
    /// goes off or the indicator stops sampling. Closing it or Show Details keeps this window's
    /// banner closed for the spell (`HostPressureService.criticalSpell`).
    private func showBanner(_ shows: Bool, verdict: HostBudgetVerdict?, spell: Int = 0) {
        guard shows else {
            // Cleared first: this end is the level's, not the person's close.
            let shown = banner
            banner = nil
            shown?.end()
            return
        }
        guard banner == nil, let window, let verdict else { return }
        // The popover's lines: the load against its limit in words, then acpmux's other reasons.
        let reasons = HostPressurePopoverView.reasons(verdict).joined(separator: "; ")
        let toast = CmuxToast(id: "host-pressure.critical", message: HostPressureStrings.banner(reasons),
                              action: CmuxToast.Action(title: HostPressureStrings.showDetails), duration: CmuxToast.untilClosed)
        let handle = toasts.show(toast, in: window)
        banner = HostPressureBanner(handle, mainWork: mainWork)
        handle.onAction = { [weak self] in self?.openPopover() }
        handle.onDismiss = { [weak self, weak handle] reason in
            guard let self, let handle, banner?.handle === handle else { return }
            banner = nil
            switch reason {
            // The close button, Show Details, or this window closing (which also ends with .closed):
            // only this window remembers it, so a closing window never keeps other windows' banners shut.
            // The spell now, not the one it was shown in: a toast still up across a quick
            // critical-warning-critical belongs to the newer spell.
            case .action, .closed: closedSpell = service.map { $0.level == .critical ? $0.criticalSpell : spell } ?? spell
            case .replaced, .timeout: break
            }
        }
    }

    private func applyTint() {
        button.contentTintColor = performWithTheme { Palette.attention }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.close() : openPopover()
    }

    func openPopover() {
        guard level != .normal else { return }
        popover.content.update(level: level, verdict: service?.verdict, canStop: service?.isForced == false)
        popover.show(relativeTo: button)
    }

    var isPopoverShown: Bool { level != .normal && popover.isShown }
    var isBannerShown: Bool { banner != nil }

    func closePopover() {
        if isPopoverShown { popover.close() }
    }

    private func makePopover() -> HostPressurePopover {
        let popover = HostPressurePopover()
        popover.content.onOpenActivity = { [weak self, weak popover] in
            popover?.close()
            _ = self?.services.registry.perform("agentActivity.open")
        }
        popover.content.onStop = { [weak self] session in self?.confirmStop(session) }
        return popover
    }

    /// Asks first; the stop keeps the session (a new message resumes it). The service asks acpmux off the main thread.
    private func confirmStop(_ session: HostBudgetSession) {
        guard let window else { return }
        let spec = CmuxDialogSpec(title: HostPressureStrings.stopTitle(session.name), lines: [HostPressureStrings.stopBody],
                                  buttons: [.cancel(),
                                            CmuxDialogButton(id: "stop", title: HostPressureStrings.stop, role: .default)],
                                  identifier: "cmux.dialog.hostPressure.stop")
        popover.close()
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { [weak self] answer in
            guard answer.button == "stop" else { return }
            self?.service?.stopSession(session)
        }
    }
}
