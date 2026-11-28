public import AppKit
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextDesign

/// Content of a window that has no workspace yet. The window opens at
/// launch with this view, so the app is never windowless while the daemon
/// is slow or unreachable. While connecting it is the empty main pane beside the
/// sidebar, as the window looks without a workspace (no cmux mark: the window must look
/// usable at once, cx-r650e). Automatic startup and restoration show no connection chatter.
/// Once the startup deadline passes, the existing failure state offers Retry Now and, for a
/// stuck owner, Restart cmux-tui, with Copy Details for the raw error.
public final class DaemonConnectingView: NSView {
    let mark = LaunchMarkView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let copyDetailsButton = ThemedBezelButton(title: "", target: nil, action: nil)
    private let recoveryControls: DaemonRecoveryControls?
    private let recovery: DaemonRecovery?
    /// Follows ``DaemonRecovery/restoring`` (about every 5 s while an owner restores); ends after this view is gone.
    private var restoreObservation: Task<Void, Never>?
    /// The failure's raw text, for Copy Details.
    private var failureDetails = ""
    /// Copy Details' write (tests read it instead of the clipboard).
    var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private(set) var state: DaemonStartupState = .connecting

    public convenience override init(frame: NSRect) {
        self.init(frame: frame, clock: ContinuousClock())
    }

    public convenience init(frame: NSRect, recovery: DaemonRecovery) {
        self.init(frame: frame, clock: ContinuousClock(), recovery: recovery)
    }

    /// - Parameters:
    ///   - clock: Kept for callers that inject the startup clock.
    ///   - recovery: The local daemon's Retry Now and Restart; nil shows neither.
    init(frame: NSRect, clock: any Clock<Duration>, recovery: DaemonRecovery? = nil) {
        recoveryControls = recovery.map(DaemonRecoveryControls.init(recovery:))
        self.recovery = recovery
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
        guard let recovery else { return }
        // task-owner: ends after this view is gone (weak self), at the recovery's next change
        restoreObservation = Task { [weak self, recovery] in
            for await _ in ObservationStream({ recovery.restoring }) {
                guard let self else { return }
                self.apply(self.state)
            }
        }
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
    }

    public func apply(_ state: DaemonStartupState) {
        self.state = state
        switch state {
        case .connecting, .connected:
            // Connected: what is left is the first workspace (cx-b4sjc), not cmux-tui, so no status line (cx-r650e).
            titleLabel.stringValue = ""
            titleLabel.alphaValue = 0
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
            copyDetailsButton.isHidden = true
            recoveryControls?.isOffered = false
        case .unavailable(let error):
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
        if state.isUnavailable, let restoring = recovery?.restoring {
            // After the failure deadline, explain a restore that still needs recovery.
            titleLabel.stringValue = RefusalStrings.restoringSessions(waitedMs: restoring.waitedMs)
            titleLabel.alphaValue = 1
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
