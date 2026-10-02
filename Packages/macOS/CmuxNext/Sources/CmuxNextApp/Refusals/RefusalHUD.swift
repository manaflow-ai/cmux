import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A short Liquid Glass message at the bottom of the window when a keyboard
/// or menu action refuses ("Not enough room to split this column"), instead
/// of a bare beep. It takes no mouse and no focus, fades through Motion
/// tokens (Reduce Motion snaps) and hides after a one-shot deadline.
@MainActor
final class RefusalHUD {
    private let view = RefusalHUDView()
    private let hideTimer: DemandTimer
    /// How long a message stays.
    var lifetime: Duration = .milliseconds(1800)
    /// Runs after the deadline hides the message (tests await it).
    var onHide: (@MainActor () -> Void)?

    /// `clock` runs the hide deadline; tests pass a manual clock.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        hideTimer = DemandTimer(owner: "App.refusalHUD.hide", clock: clock)
    }

    /// The message currently shown (tests, `debug.layers` style checks).
    var message: String? { view.isShowing ? view.text : nil }

    func show(_ text: String, in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        if view.superview !== content { content.addSubview(view, positioned: .above, relativeTo: nil) }
        view.show(text, in: content.bounds)
        hideTimer.schedule(after: lifetime) { @MainActor [weak self] in
            guard let self else { return }
            self.view.hide()
            self.onHide?()
        }
    }
}

/// The glass pill and its label.
final class RefusalHUDView: NSView {
    private let surface = OverlaySurfaceView()
    private let label = NSTextField(labelWithString: "")
    private(set) var isShowing = false
    var text: String { label.stringValue }
    /// Whether the whole message fits (tests).
    var fitsText: Bool { (label.cell?.cellSize.width ?? .infinity) <= label.frame.width + 0.5 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(surface)
        surface.contentView.addSubview(label)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, in container: CGRect) {
        label.font = Typography.bodyEmphasized
        label.stringValue = text
        setAccessibilityLabel(text)
        performWithTheme { label.textColor = Palette.textPrimary }
        surface.applyTheme()
        let inset = Metrics.space5
        let size = label.intrinsicContentSize
        // Slack for the text field's own padding, or the text truncates.
        let width = min(container.width - inset * 2, ceil(size.width) + inset * 2 + Metrics.space4)
        let height = size.height + Metrics.space4 * 2
        frame = CGRect(x: container.midX - width / 2, y: container.minY + Metrics.space6 * 2, width: width, height: height)
        surface.frame = bounds
        surface.cornerRadius = height / 2
        label.frame = bounds.insetBy(dx: inset, dy: Metrics.space4)
        isHidden = false
        isShowing = true
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Motion.animate(.fadeIn) { animator().alphaValue = 1 }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        Motion.animate(.fadeOut, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        })
    }
}
