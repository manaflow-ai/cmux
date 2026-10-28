public import AppKit
public import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextWakeups

/// Content of a window that has no workspace yet. The window opens at
/// launch with this view, so the app is never windowless while the daemon
/// is slow or unreachable. While connecting it is the empty main pane beside the
/// sidebar, as the window looks without a workspace (no cmux mark: the window must look
/// usable at once, cx-r650e); "Connecting to cmux-tui" shows after `launchTextDelay` only
/// while not yet connected, so a fast launch replaces it first. Once the startup deadline
/// passes, it shows the failure at once, in plain words, with the raw error
/// behind Copy Details for a bug report, Retry Now and, for a stuck owner,
/// Restart cmux-tui (`DaemonRecoveryControls`, cx-jniyz.1).
public final class DaemonConnectingView: NSView {
    let mark = LaunchMarkView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let copyDetailsButton = ThemedBezelButton(title: "", target: nil, action: nil)
    private let recoveryControls: DaemonRecoveryControls?
    /// The failure's raw text, for Copy Details.
    private var failureDetails = ""
    /// Copy Details' write (tests read it instead of the clipboard).
    var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private(set) var state: DaemonStartupState = .connecting
    private let statusTimer: DemandTimer
    /// The status line has waited out its delay (or a failure showed it).
    private var statusDue = false

    public convenience override init(frame: NSRect) {
        self.init(frame: frame, clock: ContinuousClock())
    }

    public convenience init(frame: NSRect, recovery: DaemonRecovery) {
        self.init(frame: frame, clock: ContinuousClock(), recovery: recovery)
    }

    /// - Parameters:
    ///   - clock: Times the status delay (tests step it).
    ///   - recovery: The local daemon's Retry Now and Restart; nil shows neither.
    init(frame: NSRect, clock: any Clock<Duration>, recovery: DaemonRecovery? = nil) {
        statusTimer = DemandTimer(owner: "launch.status", clock: clock)
        recoveryControls = recovery.map(DaemonRecoveryControls.init(recovery:))
        super.init(frame: frame)
        // Layer-backed, so the status line's fade sets its model alpha at once.
        wantsLayer = true
        titleLabel.font = Typography.body
        titleLabel.alignment = .center
        detailLabel.font = Typography.caption
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isSelectable = true
        detailLabel.focusRingType = .none
        copyDetailsButton.title = DaemonRecoveryStrings.copyDetails
        copyDetailsButton.controlSize = .small
        copyDetailsButton.target = self
        copyDetailsButton.action = #selector(copyDetails)
        copyDetailsButton.isHidden = true
        var views: [NSView] = [mark, titleLabel, detailLabel]
        if let recoveryControls { views.append(recoveryControls) }
        let stack = NSStackView(views: views + [copyDetailsButton])
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
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme {
            titleLabel.textColor = Palette.textSecondary
            detailLabel.textColor = Palette.textSecondary
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        if window == nil {
            cancelStagger()
        } else {
            staggerIfConnecting()
        }
    }

    /// While connecting in a window: the status line, after its delay from
    /// when this view entered the window.
    private func staggerIfConnecting() {
        guard window != nil, state == .connecting else { return }
        if !statusDue {
            statusTimer.scheduleIfIdle(after: .seconds(MotionTunables.launchTextDelay.value)) { @MainActor [weak self] in
                guard let self else { return }
                statusDue = true
                DaemonLaunchTimings.shared.mark("connecting_status_shown")
                Motion.panes.animate(.fadeIn, in: self.titleLabel) { self.titleLabel.animator().alphaValue = 1 }
            }
        }
    }

    private func cancelStagger() { statusTimer.cancel() }

    public func apply(_ state: DaemonStartupState) {
        self.state = state
        switch state {
        case .connecting, .connected:
            // Connected: what is left is the first workspace (cx-b4sjc), not cmux-tui, so no status line (cx-r650e).
            if state == .connected { statusTimer.cancel(); statusDue = false }
            titleLabel.stringValue = DaemonRecoveryStrings.connecting
            titleLabel.alphaValue = statusDue ? 1 : 0
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
            copyDetailsButton.isHidden = true
            recoveryControls?.isOffered = false
            staggerIfConnecting()
        case .unavailable(let error):
            cancelStagger()
            statusDue = true
            titleLabel.alphaValue = 1
            if !mark.isRevealed { mark.reveal() }
            if case .sessionRestoreTimedOut = error {
                // The service started; it is still restoring terminals.
                titleLabel.stringValue = RefusalStrings.daemonRestoreTimedOut
                detailLabel.stringValue = ""
            } else {
                titleLabel.stringValue = DaemonRecoveryStrings.serviceUnavailable
                detailLabel.stringValue = Self.plainReason(error) ?? ""
            }
            detailLabel.isHidden = detailLabel.stringValue.isEmpty
            failureDetails = String(describing: error)
            copyDetailsButton.isHidden = false
            recoveryControls?.isOffered = true
        }
        setAccessibilityLabel([titleLabel.stringValue, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    var titleText: String { titleLabel.stringValue }

    /// What the user can expect, in plain words, or nil when no advice would be true (another
    /// app serves the socket, a bad launch tag): Copy Details carries the specifics.
    private static func plainReason(_ error: DaemonError) -> String? {
        switch error {
        case .binaryNotFound: DaemonRecoveryStrings.reinstall
        case .unsupportedProtocol: RefusalStrings.restartToUpdateDaemon
        case .missingCapabilities, .sessionRestoreTimedOut: RefusalStrings.describe(error)
        case .endpointBlocked(let reason): reason
        case .wrongApp, .invalidSessionName: nil
        default: DaemonStartup.shared.isPermanent(error) ? nil : DaemonRecoveryStrings.retrying
        }
    }

    @objc private func copyDetails() {
        copyToClipboard([failureDetails, recoveryControls?.restartFailure].compactMap { $0 }.joined(separator: "\n"))
    }
}
