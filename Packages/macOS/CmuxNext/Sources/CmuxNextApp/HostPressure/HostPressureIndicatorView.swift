import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHostPressure

/// The window's host pressure indicator in the top row, after the toolbar band
/// and the incognito badge (`WindowRootView.hostPressureIndicator`; never the
/// sidebar). Hidden while the host is normal; at warning and critical a still
/// glyph in the theme's attention color (no pulse, no animation), whose click
/// opens the popover. It subscribes to the app's `HostPressureService` while it
/// is in a window, so the monitor stops when the last window closes.
final class HostPressureIndicatorView: NSView {
    static let identifier = "cmux.titlebar.hostPressure"
    let button = TitlebarBandButton(symbol: HostPressureIndicatorView.symbol(.warning))
    private let services: AppServices
    private let onVisibilityChange: () -> Void
    private var service: HostPressureService?
    private var observation: Task<Void, Never>?
    private lazy var popover: HostPressurePopover = makePopover()
    private(set) var level = HostPressureLevel.normal

    init(services: AppServices, onVisibilityChange: @escaping () -> Void) {
        self.services = services
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
        window == nil ? leave() : join()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func join() {
        guard service == nil else { return }
        let service = HostPressureService.shared(acpmux: QuitAgents.environment(services))
        self.service = service
        service.subscribe()
        // task-owner: the indicator (cancelled when it leaves its window); event-driven (Observation)
        observation = Task { [weak self] in
            for await (level, verdict) in ObservationStream({ (service.level, service.verdict) }) {
                self?.show(level: level, verdict: verdict)
            }
        }
    }

    private func leave() {
        observation?.cancel()
        observation = nil
        service?.unsubscribe()
        service = nil
        if level != .normal { popover.close() }
    }

    private func show(level: HostPressureLevel, verdict: HostBudgetVerdict?) {
        let wasHidden = isHidden
        self.level = level
        isHidden = level == .normal
        button.symbol = Self.symbol(level)
        let title = level == .critical ? HostPressureStrings.criticalTitle : HostPressureStrings.warningTitle
        button.setAccessibilityLabel(title)
        button.themedToolTip = title
        applyTint()
        if level == .normal {
            if popover.isShown { popover.close() }
        } else {
            popover.content.update(level: level, verdict: verdict)
        }
        if wasHidden != isHidden { onVisibilityChange() }
    }

    private func applyTint() {
        button.contentTintColor = performWithTheme { Palette.attention }
    }

    @objc private func togglePopover() {
        if popover.isShown { return popover.close() }
        popover.content.update(level: level, verdict: service?.verdict)
        popover.show(relativeTo: button)
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

    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            service?.unsubscribe()
        }
    }
}
