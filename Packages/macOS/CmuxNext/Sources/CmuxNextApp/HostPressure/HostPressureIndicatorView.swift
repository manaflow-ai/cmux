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
/// remove the window and app observers, cancel the toggle and level observations and
/// unsubscribe (`HostPressureSubscription` also ends itself if it is released without that). While the toggle is off it never creates the service at all.
final class HostPressureIndicatorView: NSView {
    static let identifier = "cmux.titlebar.hostPressure"
    let button = TitlebarBandButton(symbol: HostPressureIndicatorView.symbol(.warning))
    private let services: AppServices
    private let store: TunableStore
    private let windowVisible: @MainActor (NSWindow?) -> Bool
    private let makeService: @MainActor () -> HostPressureService
    private let onVisibilityChange: () -> Void
    private var subscription: HostPressureSubscription?
    private var service: HostPressureService? { subscription?.service }
    private var observation: Task<Void, Never>?
    private var toggleObservation: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private lazy var popover: HostPressurePopover = makePopover()
    private(set) var level = HostPressureLevel.normal
    /// Whether it is subscribed to the service now (tests read it).
    var isSampling: Bool { service != nil }

    /// `store`, `windowVisible` and `service` are for tests; the app passes none.
    init(services: AppServices, store: TunableStore = .shared,
         windowVisible: @escaping @MainActor (NSWindow?) -> Bool = HostPressureSampling.isVisible,
         service: (@MainActor () -> HostPressureService)? = nil,
         onVisibilityChange: @escaping () -> Void) {
        self.services = services
        self.store = store
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

    /// The window's visibility notifications and the toggle, while in a window.
    private func observeWindow() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        toggleObservation?.cancel()
        toggleObservation = nil
        guard let window else { return }
        windowObservers = HostPressureSampling.appChanges.map { name in
            NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() } // main-proof: observer on queue: .main
            }
        }
        windowObservers += HostPressureSampling.windowChanges.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    closing ? self?.leave() : self?.reconcile()
                }
            }
        }
        let (store, enabled) = (store, HostPressureTunables.enabled)
        // task-owner: the indicator (cancelled when it leaves its window and in deinit); event-driven (Observation of the tunable store)
        toggleObservation = Task { [weak self] in
            for await _ in ObservationStream({ enabled.value(in: store) }) {
                self?.reconcile()
            }
        }
    }

    private func join() {
        guard subscription == nil else { return }
        let service = makeService()
        subscription = HostPressureSubscription(service)
        // task-owner: the indicator (cancelled when it stops sampling); event-driven (Observation)
        observation = Task { [weak self] in
            for await (level, verdict) in ObservationStream({ (service.level, service.verdict) }) {
                self?.show(level: level, verdict: verdict)
            }
        }
    }

    private func leave() {
        guard let subscription else { return }
        observation?.cancel()
        observation = nil
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
            popover.content.update(level: level, verdict: verdict)
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
        popover.content.update(level: level, verdict: service?.verdict)
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

    /// Off the main thread it leaves the cleanup to its parts: the subscription ends itself on
    /// the main actor when released, and the observers and tasks hold the indicator weakly.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
            toggleObservation?.cancel()
            observation?.cancel()
            subscription?.cancel()
        }
    }
}
