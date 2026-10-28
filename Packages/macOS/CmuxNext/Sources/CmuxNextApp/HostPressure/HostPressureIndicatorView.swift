import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHostPressure

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
/// only while `HostPressureSampling.samples` holds (the Debug Settings toggle
/// `hostPressure.enabled` is on and its window can be seen). Stop condition: the
/// toggle going off, or the window (or the whole app) hiding, minimizing, being fully occluded or
/// closing, unsubscribes it, and the service stops the monitor and its one 15 s
/// timer when no window is subscribed. Cleanup: leaving the window, and deinit,
/// cancel the notification, toggle and level observations (from any thread) and
/// unsubscribe (`HostPressureSubscription` ends itself if it is released without that). While the toggle is off it never creates the service at all.
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
    private let windowVisible: @MainActor (NSWindow?) -> Bool
    private let makeService: @MainActor () -> HostPressureService
    private let notifications: NotificationCenter
    private let toasts: CmuxToastCenter
    private let onVisibilityChange: () -> Void
    private var subscription: HostPressureSubscription?
    private var service: HostPressureService? { subscription?.service }
    /// The notification and toggle observations while in a window, and the level observation
    /// while subscribed; both cancel from any thread, the nonisolated deinit included.
    private let watching = HostPressureTasks()
    private let levels = HostPressureTasks()
    private lazy var popover: HostPressurePopover = makePopover()
    private(set) var level = HostPressureLevel.normal
    /// Whether it is subscribed to the service now (tests read it).
    var isSampling: Bool { service != nil }

    /// `store`, `notifications`, `windowVisible`, `service` and `toasts` are for tests; the app passes none.
    init(services: AppServices, store: TunableStore = .shared, notifications: NotificationCenter = .default,
         windowVisible: @escaping @MainActor (NSWindow?) -> Bool = HostPressureSampling.isVisible,
         service: (@MainActor () -> HostPressureService)? = nil, toasts: CmuxToastCenter = .shared,
         onVisibilityChange: @escaping () -> Void) {
        self.services = services
        self.store = store
        self.notifications = notifications
        self.toasts = toasts
        self.windowVisible = windowVisible
        self.makeService = service ?? { HostPressureService.shared(acpmux: QuitAgents.environment(services)) }
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// The gate's inputs now: the toggle and whether the window can be seen. A forced level
    /// (Debug Settings only, for captures) counts as seen while the indicator is in a window:
    /// capture minis run windows the occlusion state calls hidden. The 15 s read then runs while
    /// the level stays forced; Off restores the window gate, and leaving the window still stops it.
    var sampling: HostPressureSampling {
        let forced = HostPressureTunables.force.value(in: store) != .off && window != nil
        return HostPressureSampling(enabled: HostPressureTunables.enabled.value(in: store),
                                    windowVisible: forced || windowVisible(window))
    }

    /// Subscribes while `sampling.samples`, else unsubscribes (idempotent).
    func reconcile() {
        sampling.samples ? join() : leave()
    }

    /// The window's and the app's visibility notifications and the toggle, while in a window.
    /// They are tasks in `watching`, which a window change, `willClose` and deinit cancel (from
    /// any thread).
    private func observeWindow() {
        watching.cancelAll()
        guard let window else { return }
        let center = notifications
        let names = HostPressureSampling.windowChanges.map { ($0, window as AnyObject) } + HostPressureSampling.appChanges.map { ($0, NSApplication.shared as AnyObject) }
        for (name, object) in names {
            let closing = name == NSWindow.willCloseNotification
            // task-owner: `watching` (cancelled on a window change, on willClose and in deinit); event-driven (one notification)
            watching.add(Task { [weak self, weak object] in
                guard let object else { return }
                for await _ in center.notifications(named: name, object: object) {
                    // Cancelled (willClose, a window change) on the main actor before this body ran: nothing.
                    guard !Task.isCancelled, let self else { return }
                    if closing {
                        leave()
                        watching.cancelAll()
                    } else {
                        reconcile()
                    }
                }
            })
        }
        let (store, enabled, force) = (store, HostPressureTunables.enabled, HostPressureTunables.force)
        // task-owner: `watching` (cancelled on a window change, on willClose and in deinit); event-driven (Observation of the tunable store)
        watching.add(Task { [weak self] in
            for await _ in ObservationStream({ (enabled.value(in: store), force.value(in: store)) }) {
                guard !Task.isCancelled, let self else { return }
                reconcile()
            }
        })
    }

    private func join() {
        guard subscription == nil else { return }
        let service = makeService()
        subscription = HostPressureSubscription(service)
        // task-owner: `levels` (cancelled when it stops sampling and in deinit); event-driven (Observation)
        let store = store
        levels.add(Task { [weak self] in
            for await (level, verdict, style, bannerOn, spell) in ObservationStream({
                (service.level, service.verdict, HostPressureTunables.style.value(in: store),
                 HostPressureTunables.banner.value(in: store), service.criticalSpell)
            }) {
                // A value queued before leave() cancelled this shows nothing.
                guard !Task.isCancelled, let self else { return }
                self.style = style
                show(level: level, verdict: verdict)
                showBanner(bannerOn && level == .critical && closedSpell != spell, verdict: verdict, spell: spell)
            }
        })
    }

    private func leave() {
        guard let subscription else { return }
        levels.cancelAll()
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
        if wasHidden != isHidden || oldWidth != width {
            // The root lays the top row out: without this its layoutSubtreeIfNeeded keeps the old frame
            // (zero the first time) until something else relayouts the window.
            superview?.needsLayout = true
            onVisibilityChange()
        }
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
        banner = HostPressureBanner(handle)
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

    /// Asks first; the stop keeps the session (a new message resumes it).
    private func confirmStop(_ session: HostBudgetSession) {
        guard let window else { return }
        let spec = CmuxDialogSpec(title: HostPressureStrings.stopTitle(session.name), lines: [HostPressureStrings.stopBody],
                                  buttons: [.cancel(),
                                            CmuxDialogButton(id: "stop", title: HostPressureStrings.stop, role: .default)],
                                  identifier: "cmux.dialog.hostPressure.stop")
        popover.close()
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { [weak self] answer in
            guard answer.button == "stop", let service = self?.service else { return }
            // task-owner: one stop request; it ends when acpmux answers (5 s deadline)
            Task { _ = await service.stopSession(session) }
        }
    }

    /// Cancels every observation on whatever thread it runs; the subscription and the banner end
    /// themselves on the main actor when they are released (`HostPressureSubscription`,
    /// `HostPressureBanner`).
    nonisolated deinit {
        watching.cancelAll()
        levels.cancelAll()
    }
}
