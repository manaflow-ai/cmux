import AppKit
import CmuxNextCompat
public import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextWakeups

/// Strings of the launch window's connecting and failure screen and the
/// daemon recovery controls (Resources/Localizable.xcstrings).
enum DaemonRecoveryStrings {
    static var connecting: String { String(localized: "daemon.connecting", defaultValue: "Connecting to cmux-tui…", bundle: .module) }
    static var serviceUnavailable: String {
        String(localized: "daemon.serviceUnavailable", defaultValue: "cmux couldn’t start its background service.", bundle: .module)
    }
    static var reinstall: String { String(localized: "daemon.reinstall", defaultValue: "Reinstall cmux to fix this.", bundle: .module) }
    static var copyDetails: String { String(localized: "daemon.copyDetails", defaultValue: "Copy Details", bundle: .module) }
    static var retrying: String { String(localized: "daemon.retrying", defaultValue: "Still retrying in the background.", bundle: .module) }
    static var retryNow: String { String(localized: "daemon.recovery.retryNow", defaultValue: "Retry Now", bundle: .module) }
    static var restart: String { String(localized: "daemon.recovery.restart", defaultValue: "Restart cmux-tui", bundle: .module) }
    static var confirmTitle: String { String(localized: "daemon.recovery.confirmTitle", defaultValue: "Restart cmux-tui?", bundle: .module) }
    static var confirmBody: String {
        String(localized: "daemon.recovery.confirmBody",
               defaultValue: "cmux-tui is not responding. Restarting it stops the stuck process and starts a new one. Terminals running in it may be lost.",
               bundle: .module)
    }
    static var confirmButton: String { String(localized: "daemon.recovery.confirmButton", defaultValue: "Restart", bundle: .module) }
    static var restarting: String { String(localized: "daemon.recovery.restarting", defaultValue: "Restarting cmux-tui…", bundle: .module) }
    static var failed: String {
        String(localized: "daemon.recovery.failed", defaultValue: "cmux-tui could not be restarted. Try again in a moment.", bundle: .module)
    }
}

/// Restart cmux-tui's question and the App Store banner's controls, one path
/// for both surfaces (cx-jniyz.1). The question is the cmux dialog every
/// destructive confirm uses, so the debug socket can answer it.
enum DaemonRestartPrompt {
    static let confirmID = "restart"
    static let identifier = "cmux.dialog.restartDaemon"

    /// Asks before Restart cmux-tui (terminals of a stuck owner may be lost),
    /// then runs it. `window` scopes the question; none asks app-wide.
    static func confirm(_ recovery: DaemonRecovery, in window: NSWindow?) {
        let spec = CmuxDialogSpec(title: DaemonRecoveryStrings.confirmTitle, lines: [DaemonRecoveryStrings.confirmBody],
                                  buttons: [.cancel(), CmuxDialogButton(id: confirmID, title: DaemonRecoveryStrings.confirmButton, role: .default)],
                                  identifier: identifier)
        CmuxDialogCenter.shared.present(spec, in: window.map(CmuxDialogScope.window) ?? .app) { answer in
            guard answer.button == confirmID else { return }
            // task-owner: one restart per confirm; DaemonRecovery ignores another while one runs
            Task { await recovery.restart() }
        }
    }

    /// What the restart shows while it runs or after it failed; nil otherwise.
    static func status(_ recovery: DaemonRecovery) -> String? {
        if recovery.isRestarting { return DaemonRecoveryStrings.restarting }
        return recovery.restartFailure == nil ? nil : DaemonRecoveryStrings.failed
    }
}

/// Retry Now and Restart cmux-tui under the launch window's failure
/// (cx-jniyz.1). Restart shows only once a plain ensure failed as a stuck
/// owner makes it fail (`DaemonRecovery.offersRestart`).
final class DaemonRecoveryControls: NSStackView {
    private let recovery: DaemonRecovery
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = ThemedBezelButton(title: "", target: nil, action: nil)
    private let restartButton = ThemedBezelButton(title: "", target: nil, action: nil)
    /// The recovery's state, read only while the window shows (recipe R-obs: a view apply).
    private var observation: VisibleObservation<(offersRestart: Bool, isRestarting: Bool, failure: String?)>?
    /// The window shows a failure: the controls show only then.
    var isOffered = false { didSet { refresh() } }

    /// - Parameters:
    ///   - recovery: The local daemon's recovery.
    ///   - node: The window's visibility node: a hidden window's controls catch up when it shows.
    ///   - work: The app's main-thread scheduler.
    init(recovery: DaemonRecovery, node: VisibilityNode, on work: MainWorkScheduler) {
        self.recovery = recovery
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Metrics.space2
        statusLabel.font = Typography.caption
        statusLabel.alignment = .center
        statusLabel.isSelectable = true
        statusLabel.focusRingType = .none
        statusLabel.setAccessibilityIdentifier("daemon.recoveryStatus")
        Self.configure(retryButton, title: DaemonRecoveryStrings.retryNow, identifier: "daemon.retryNow", target: self, action: #selector(retryNow))
        Self.configure(restartButton, title: DaemonRecoveryStrings.restart, identifier: "daemon.restart", target: self, action: #selector(confirmRestart))
        let row = NSStackView(views: [retryButton, restartButton])
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        addArrangedSubview(statusLabel)
        addArrangedSubview(row)
        // Its first apply refreshes now; a tuple applies every change (no dedupe), as the loop it replaced did.
        observation = VisibleObservation(node, owner: "DaemonRecoveryControls", on: work) { [recovery] in
            (offersRestart: recovery.offersRestart, isRestarting: recovery.isRestarting, failure: recovery.restartFailure)
        } apply: { [weak self] _ in
            self?.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func configure(_ button: NSButton, title: String, identifier: String, target: AnyObject, action: Selector) {
        button.title = title
        button.controlSize = .small
        button.target = target
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    // visibility-walk-allow: one label color store in the theme scope, no layout or text measure; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { statusLabel.textColor = Palette.textSecondary }
    }

    /// The restart's failure, for Copy Details.
    var restartFailure: String? { recovery.restartFailure }

    private func refresh() {
        let restarting = recovery.isRestarting
        isHidden = !isOffered || !recovery.canRetry
        retryButton.isEnabled = !restarting
        restartButton.isHidden = !(recovery.offersRestart || restarting)
        restartButton.isEnabled = !restarting
        statusLabel.stringValue = DaemonRestartPrompt.status(recovery) ?? ""
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    @objc private func retryNow() {
        recovery.retryNow()
    }

    @objc private func confirmRestart() {
        DaemonRestartPrompt.confirm(recovery, in: window)
    }
}
