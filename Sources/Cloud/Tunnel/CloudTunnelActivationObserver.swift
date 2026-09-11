import Foundation

/// Brings the app-managed tunnel down when Cloud Machines is turned off while
/// the app runs, so "no tunnel while Cloud Machines is off" holds without a
/// relaunch. Turning it back on needs nothing here: every start asks
/// ``CloudActivationPolicy`` again.
@MainActor
final class CloudTunnelActivationObserver {
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - notificationCenter: Where the Beta Features toggle posts its change.
    ///   - isStartRefused: The policy's answer, read at startup and after every change.
    ///   - bringDown: Runs when the policy refuses.
    init(
        notificationCenter: NotificationCenter = .default,
        isStartRefused: @escaping @Sendable () -> Bool,
        bringDown: @escaping @Sendable () async -> Void
    ) {
        observation = Task {
            // `notifications(named:)` registers when iteration begins, which
            // is later than this init returns. Reconcile once first so a
            // toggle change posted in between is not missed, and a tunnel
            // that is already refused at startup comes down.
            if isStartRefused() {
                await bringDown()
            }
            let changes = notificationCenter.notifications(named: RightSidebarBetaFeatureSettings.didChangeNotification)
            for await _ in changes {
                guard isStartRefused() else { continue }
                await bringDown()
            }
        }
    }

    deinit {
        observation?.cancel()
    }
}
