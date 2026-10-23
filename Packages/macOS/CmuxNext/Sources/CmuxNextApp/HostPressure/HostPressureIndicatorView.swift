import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHostPressure

/// The window's host pressure indicator in the top row, after the toolbar band
/// and the incognito badge (`WindowRootView.hostPressureIndicator`; never the
/// sidebar). Hidden while the host is normal; at warning and critical a still
/// glyph in the theme's attention color (no pulse, no animation), whose click
/// opens the popover.
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
    let button = TitlebarBandButton(symbol: HostPressureIndicatorView.symbol(.warning))
    private let services: AppServices
    private let store: TunableStore
    private let windowVisible: @MainActor (NSWindow?) -> Bool
    private let makeService: @MainActor () -> HostPressureService
    private let notifications: NotificationCenter
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

    /// `store`, `notifications`, `windowVisible` and `service` are for tests; the app passes none.
    init(services: AppServices, store: TunableStore = .shared, notifications: NotificationCenter = .default,
         windowVisible: @escaping @MainActor (NSWindow?) -> Bool = HostPressureSampling.isVisible,
         service: (@MainActor () -> HostPressureService)? = nil,
         onVisibilityChange: @escaping () -> Void) {
        self.services = services
        self.store = store
        self.notifications = notifications
        self.windowVisible = windowVisible
        self.makeService = service ?? { HostPressureService.shared(acpmux: QuitAgents.environment(services)) }
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
        isHidden = true
        button.target = self
        button.action = #selector(togglePopover)
        button.setAccessibilityIdentifier(Self.identifier)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ level: HostPressureLevel) -> String {
        level == .critical ? "exclamationmark.triangle" : "gauge.with.dots.needle.67percent"
    }

    static var side: CGFloat { TitlebarBandButton.side }

    override func layout() {
        super.layout()
        button.frame = bounds
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

    /// The gate's inputs now: the toggle and whether the window can be seen.
    var sampling: HostPressureSampling {
        HostPressureSampling(enabled: HostPressureTunables.enabled.value(in: store), windowVisible: windowVisible(window))
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
        let (store, enabled) = (store, HostPressureTunables.enabled)
        // task-owner: `watching` (cancelled on a window change, on willClose and in deinit); event-driven (Observation of the tunable store)
        watching.add(Task { [weak self] in
            for await _ in ObservationStream({ enabled.value(in: store) }) {
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
        levels.add(Task { [weak self] in
            for await (level, verdict) in ObservationStream({ (service.level, service.verdict) }) {
                // A value queued before leave() cancelled this shows nothing.
                guard !Task.isCancelled, let self else { return }
                show(level: level, verdict: verdict)
            }
        })
    }

    private func leave() {
        guard let subscription else { return }
        levels.cancelAll()
        subscription.cancel()
        self.subscription = nil
        show(level: .normal, verdict: nil)
    }

    private func show(level: HostPressureLevel, verdict: HostBudgetVerdict?) {
        let (wasHidden, wasLevel) = (isHidden, self.level)
        self.level = level
        isHidden = level == .normal
        button.symbol = Self.symbol(level)
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
        if wasHidden != isHidden { onVisibilityChange() }
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

    /// Cancels every observation on whatever thread it runs; the subscription ends itself on
    /// the main actor when it is released (`HostPressureSubscription`).
    nonisolated deinit {
        watching.cancelAll()
        levels.cancelAll()
    }
}
