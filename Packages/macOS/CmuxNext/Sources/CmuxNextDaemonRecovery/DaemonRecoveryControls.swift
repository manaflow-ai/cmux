import AppKit
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextWakeups

/// Strings of the launch window's connecting and failure screen and the
/// daemon recovery controls (Resources/Localizable.xcstrings).
enum DaemonRecoveryStrings {
    static var connecting: String { String(localized: "daemon.connecting", defaultValue: "Starting cmux…", bundle: .localizedModule) }
    static var serviceUnavailable: String {
        String(localized: "daemon.serviceUnavailable", defaultValue: "cmux couldn’t start its background service.", bundle: .localizedModule)
    }
    static var reinstall: String { String(localized: "daemon.reinstall", defaultValue: "Reinstall cmux to fix this.", bundle: .localizedModule) }
    static var copyDetails: String { String(localized: "daemon.copyDetails", defaultValue: "Copy Details", bundle: .localizedModule) }
    static var retrying: String { String(localized: "daemon.retrying", defaultValue: "Still retrying in the background.", bundle: .localizedModule) }
    static var restart: String { String(localized: "daemon.recovery.restart", defaultValue: "Restart Background Service", bundle: .localizedModule) }
    static var restarting: String { String(localized: "daemon.recovery.restarting", defaultValue: "Restarting the background service…", bundle: .localizedModule) }
    // retry-prompt-ok: shown after the person's own Restart failed; Restart replaces the service (a side effect).
    static var failed: String {
        String(localized: "daemon.recovery.failed", defaultValue: "Couldn't restart the background service. Try again in a moment.", bundle: .localizedModule)
    }
    /// Why cmux-tui is not running, when its start failed because the disk is full (restore fuzz h2): the one
    /// disk-full reason a refused change also shows (`RefusalStrings.diskFull`, restore fuzz h3).
    static var diskFull: String {
        String(format: String(localized: "daemon.recovery.diskFull",
                              defaultValue: "cmux's background service couldn't start: %@. Free some space and cmux starts it again by itself.",
                              bundle: .localizedModule), RefusalStrings.diskFull)
    }
    /// Why cmux-tui is not running, when its start failed for any other reason.
    static var stopped: String {
        String(localized: "daemon.recovery.stopped",
               defaultValue: "cmux's background service stopped and couldn't start again. cmux keeps trying.", bundle: .localizedModule)
    }

    /// What the person reads about a failed start: the full disk, or the short generic reason.
    static func startFailed(_ failure: DaemonStartFailure?) -> String {
        failure?.isDiskFull == true ? diskFull : stopped
    }
}

/// Restart cmux-tui from the launch window's button and the App Store banner, one path for both
/// surfaces (cx-jniyz.1). No question first: the terminal hosts are separate processes that
/// outlive the stuck owner and the next owner adopts them (`DaemonRecovery.restart`), so nothing
/// is lost, and the automatic restart already runs the same replace without asking.
enum DaemonRestart {
    /// Runs Restart cmux-tui.
    static func restart(_ recovery: DaemonRecovery) {
        // task-owner: one restart per click; DaemonRecovery ignores another while one runs
        Task { await recovery.restart() }
    }

    /// What the restart shows while it runs or after it failed, or that the start failed on a
    /// full disk (restore fuzz h2); nil otherwise.
    static func status(_ recovery: DaemonRecovery) -> String? {
        if recovery.isRestarting { return DaemonRecoveryStrings.restarting }
        if recovery.restartFailure != nil { return DaemonRecoveryStrings.failed }
        return recovery.startFailure?.isDiskFull == true ? DaemonRecoveryStrings.diskFull : nil
    }
}

/// Restart cmux-tui under the launch window's failure (cx-jniyz.1). Restart shows once a plain
/// ensure failed, or the connected daemon stopped answering (`DaemonRecovery.offersRestart`).
///
/// No Retry Now: the connection already tries again by itself at least every 30 s
/// (`RetryPolicy.localFirstConnect`, `keepsTrying`), and a Retry Now only skipped that wait. Leo,
/// 2026-11-22: "i dont know what kind of decision a "try again" would be other than "ok i guess
/// ill click this."" The window becoming key (the person came to look) tries at once instead.
final class DaemonRecoveryControls: NSStackView {
    private let recovery: DaemonRecovery
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let restartButton = ThemedBezelButton(title: "", target: nil, action: nil)
    private var observation: Task<Void, Never>?
    private weak var followedWindow: NSWindow?
    /// The window shows a failure: the controls show only then.
    var isOffered = false { didSet { refresh() } }

    init(recovery: DaemonRecovery) {
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
        Self.configure(restartButton, title: DaemonRecoveryStrings.restart, identifier: "daemon.restart", target: self, action: #selector(restart))
        // retry-prompt-ok: Restart stops the stuck owner and starts a new one (a side effect), not a retry of the connect.
        let row = NSStackView(views: [restartButton])
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        addArrangedSubview(statusLabel)
        addArrangedSubview(row)
        refresh()
        // task-owner: ends after this view is gone (weak self), at the recovery's next change
        observation = Task { [weak self, recovery] in
            for await _ in ObservationStream({ (recovery.offersRestart, recovery.isRestarting, recovery.restartFailure, recovery.startFailure) }) {
                guard let self else { return }
                self.refresh()
            }
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

    /// The failure's window came back into sight: try to connect now rather than at the next
    /// backoff step (what the removed Retry Now did, without asking for the click). Told by the
    /// app's one occlusion observer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let followedWindow { FrameScheduler.unfollowSight(of: followedWindow, owner: self) }
        followedWindow = window
        guard let window else { return }
        FrameScheduler.followSight(of: window, owner: self) { [weak self, weak window] in
            guard let self, let window, !FrameScheduler.windowIsOutOfSight(window), isOffered, !isHidden,
                  !recovery.isRestarting else { return }
            recovery.retryNow()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { statusLabel.textColor = Palette.textSecondary }
    }

    /// The restart's failure, for Copy Details.
    var restartFailure: String? { recovery.restartFailure }

    private func refresh() {
        let restarting = recovery.isRestarting
        isHidden = !isOffered || !recovery.canRetry
        restartButton.isHidden = !(recovery.offersRestart || restarting)
        restartButton.isEnabled = !restarting
        statusLabel.stringValue = DaemonRestart.status(recovery) ?? ""
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    @objc private func restart() {
        DaemonRestart.restart(recovery)
    }
}
