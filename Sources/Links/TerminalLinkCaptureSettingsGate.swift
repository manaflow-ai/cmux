import CmuxFoundation
import Foundation

/// Publishes a lock-free enablement gate to Ghostty's synchronous PTY callback.
///
/// SAFETY: the only cross-thread mutation uses `AtomicBooleanGate`. UserDefaults
/// is documented thread-safe, and the NotificationCenter token is installed and
/// removed only during the gate's main-actor-owned lifecycle.
final class TerminalLinkCaptureSettingsGate: @unchecked Sendable {
    private let settings: LinksCaptureSettings
    private let enabledGate: AtomicBooleanGate
    private let notificationCenter: NotificationCenter
    private var defaultsObserver: NSObjectProtocol?

    @MainActor
    init(
        settings: LinksCaptureSettings = LinksCaptureSettings(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.settings = settings
        let snapshot = settings.snapshot()
        self.enabledGate = AtomicBooleanGate(snapshot.enabled)
        self.notificationCenter = notificationCenter
        self.defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
    }

    func isEnabled() -> Bool {
        enabledGate.loadAcquire()
    }

    func currentSnapshot() -> LinkCaptureSettingsSnapshot {
        settings.snapshot()
    }

    func refresh() {
        enabledGate.storeRelease(settings.snapshot().enabled)
    }
}
