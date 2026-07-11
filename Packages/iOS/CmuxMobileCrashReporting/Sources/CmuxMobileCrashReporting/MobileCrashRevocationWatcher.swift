internal import CmuxMobileAnalytics
internal import Foundation

/// Watches the shared telemetry-consent setting for process-lifetime transitions.
///
/// UserDefaults changes are observed through `UserDefaults.didChangeNotification`,
/// the same backing store the consent provider reads.
// Safety: the app composition root is the single owner that calls `arm`.
// Notification callbacks enqueue onto the private serial lifecycle queue;
// all mutable transition state is confined to that queue after setup.
public final class MobileCrashRevocationWatcher: @unchecked Sendable {
    private let lifecycleQueue = DispatchQueue(label: "dev.cmux.ios.crash-consent-lifecycle")
    private var token: (any NSObjectProtocol)?
    private var center: NotificationCenter?
    private var isEnabled: Bool?
    private var onEnable: CrashLifecycleAction?
    private var onRevoke: CrashLifecycleAction?

    /// Creates a process-owned watcher. Tests use one instance per case.
    public init() {}

    deinit {
        if let token, let center { center.removeObserver(token) }
    }

    func arm(
        consent: any AnalyticsConsentProviding,
        notificationCenter: NotificationCenter,
        onEnable: @escaping () -> Void,
        onRevoke: @escaping () -> Void,
        onInitiallyDisabled: @escaping () -> Void
    ) {
        if let token, let center { center.removeObserver(token) }
        let initialIsEnabled = consent.isTelemetryEnabled
        center = notificationCenter
        if initialIsEnabled {
            onEnable()
        } else {
            onInitiallyDisabled()
        }
        let enableAction = CrashLifecycleAction(body: onEnable)
        let revokeAction = CrashLifecycleAction(body: onRevoke)
        lifecycleQueue.async { [self] in
            isEnabled = initialIsEnabled
            self.onEnable = enableAction
            self.onRevoke = revokeAction
        }
        token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            let nextIsEnabled = consent.isTelemetryEnabled
            self.lifecycleQueue.async { [self] in
                guard nextIsEnabled != isEnabled else { return }
                isEnabled = nextIsEnabled
                (nextIsEnabled ? self.onEnable : self.onRevoke)?.body()
            }
        }
    }
}
