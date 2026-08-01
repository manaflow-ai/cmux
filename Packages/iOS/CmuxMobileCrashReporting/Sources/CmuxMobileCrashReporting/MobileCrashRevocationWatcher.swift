internal import CmuxMobileAnalytics
internal import Foundation

// Safety: the app composition root is the single owner that calls `arm`.
// Initial transition state is installed before the observer becomes reachable;
// notification callbacks then confine every transition to the lifecycle queue.
/// Watches the shared telemetry-consent setting for process-lifetime transitions.
///
/// UserDefaults changes are observed through `UserDefaults.didChangeNotification`,
/// the same backing store the consent provider reads.
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
        let enableAction = CrashLifecycleAction(body: onEnable)
        let revokeAction = CrashLifecycleAction(body: onRevoke)
        isEnabled = initialIsEnabled
        self.onEnable = enableAction
        self.onRevoke = revokeAction
        if initialIsEnabled {
            enableAction.body()
        } else {
            onInitiallyDisabled()
        }
        token = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            self.lifecycleQueue.async { [self] in
                let nextIsEnabled = consent.isTelemetryEnabled
                guard nextIsEnabled != isEnabled else { return }
                isEnabled = nextIsEnabled
                (nextIsEnabled ? self.onEnable : self.onRevoke)?.body()
            }
        }
        lifecycleQueue.async { [self] in
            let reconciledIsEnabled = consent.isTelemetryEnabled
            guard reconciledIsEnabled != isEnabled else { return }
            isEnabled = reconciledIsEnabled
            (reconciledIsEnabled ? self.onEnable : self.onRevoke)?.body()
        }
    }
}
