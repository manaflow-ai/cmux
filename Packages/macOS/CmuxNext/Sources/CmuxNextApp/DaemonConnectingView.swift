import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups

/// Content of a window that has no workspace yet. The window opens at
/// launch with this view, so the app is never windowless while the daemon
/// is slow or unreachable. While connecting it is the bare glass at first;
/// the cmux mark resolves in after `MotionTunables.launchMarkDelay` and
/// "Connecting to cmux-tui" follows after `launchTextDelay`, so a fast
/// launch replaces it before either shows. Once the startup deadline
/// passes, it shows the failure at once.
final class DaemonConnectingView: NSView {
    let mark = LaunchMarkView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var state: DaemonStartupState = .connecting
    private let markTimer: DemandTimer
    private let statusTimer: DemandTimer
    /// The status line has waited out its delay (or a failure showed it).
    private var statusDue = false

    convenience override init(frame: NSRect) {
        self.init(frame: frame, clock: ContinuousClock())
    }

    /// - Parameter clock: Times the mark and status delays (tests step it).
    init(frame: NSRect, clock: any Clock<Duration>) {
        markTimer = DemandTimer(owner: "launch.mark", clock: clock)
        statusTimer = DemandTimer(owner: "launch.status", clock: clock)
        super.init(frame: frame)
        // Layer-backed, so the status line's fade sets its model alpha at once.
        wantsLayer = true
        titleLabel.font = Typography.body
        titleLabel.alignment = .center
        detailLabel.font = Typography.caption
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isSelectable = true
        let stack = NSStackView(views: [mark, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(.connecting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme {
            titleLabel.textColor = Palette.textSecondary
            detailLabel.textColor = Palette.textSecondary
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        if window == nil {
            cancelStagger()
        } else {
            staggerIfConnecting()
        }
    }

    /// While connecting in a window: the mark, then the status line, each
    /// after its delay from when this view entered the window.
    private func staggerIfConnecting() {
        guard window != nil, !state.isUnavailable else { return }
        if !mark.isRevealed {
            markTimer.scheduleIfIdle(after: .seconds(MotionTunables.launchMarkDelay.value)) { @MainActor [weak self] in
                self?.mark.reveal()
            }
        }
        if !statusDue {
            statusTimer.scheduleIfIdle(after: .seconds(MotionTunables.launchTextDelay.value)) { @MainActor [weak self] in
                guard let self else { return }
                statusDue = true
                Motion.animate(.fadeIn, in: self.titleLabel) { self.titleLabel.animator().alphaValue = 1 }
            }
        }
    }

    private func cancelStagger() {
        markTimer.cancel()
        statusTimer.cancel()
    }

    func apply(_ state: DaemonStartupState) {
        self.state = state
        switch state {
        case .connecting, .connected:
            titleLabel.stringValue = Strings.daemonConnecting
            titleLabel.alphaValue = statusDue ? 1 : 0
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
            staggerIfConnecting()
        case .unavailable(let error):
            cancelStagger()
            statusDue = true
            titleLabel.alphaValue = 1
            if !mark.isRevealed { mark.reveal() }
            titleLabel.stringValue = Strings.daemonUnavailable
            detailLabel.stringValue = DaemonStartup.shared.isPermanent(error)
                ? error.description
                : "\(error.description)\n\(Strings.daemonRetrying)"
            detailLabel.isHidden = false
        }
        setAccessibilityLabel([titleLabel.stringValue, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    var titleText: String { titleLabel.stringValue }
    /// The status line shows or is fading in (it keeps its space while
    /// hidden, so nothing moves when it appears).
    var isTitleShown: Bool { statusDue }
}
