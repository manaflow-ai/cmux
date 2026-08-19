import AppKit
import Foundation

/// Applies MDM managed-policy transitions to a running app.
///
/// When the embedded-browser policy activates it runs the injected browser
/// enforcement (closing live browser panes) and posts
/// `BrowserAvailabilitySettings.didChangeNotification` so gated UI refreshes;
/// when the remote-control policy flips either way it runs the injected
/// mobile enforcement (`MobileHostService.syncToSettings()`, which tears the
/// host down or re-arms it).
///
/// Managed-preference pushes do not reliably fire
/// `UserDefaults.didChangeNotification`, so the observer also re-evaluates
/// on app activation — a profile installed while cmux is frontmost-inactive
/// takes effect the next time the user returns to the app at the latest.
@MainActor
final class ManagedPolicyEnforcementObserver {
    private let notificationCenter: NotificationCenter
    private let isBrowserDisabledByPolicy: () -> Bool
    private let isRemoteControlDisabledByPolicy: () -> Bool
    private let enforceBrowserPolicy: () -> Void
    private let enforceRemoteControlPolicy: () -> Void
    private var browserPolicyActive: Bool
    private var remoteControlPolicyActive: Bool
    private var observationTasks: [Task<Void, Never>] = []

    init(
        notificationCenter: NotificationCenter = .default,
        isBrowserDisabledByPolicy: @escaping () -> Bool = {
            BrowserAvailabilitySettings.isManagedByPolicy
        },
        isRemoteControlDisabledByPolicy: @escaping () -> Bool = {
            MobileRemoteControlPolicy.isDisabled
        },
        enforceBrowserPolicy: @escaping () -> Void,
        enforceRemoteControlPolicy: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.isBrowserDisabledByPolicy = isBrowserDisabledByPolicy
        self.isRemoteControlDisabledByPolicy = isRemoteControlDisabledByPolicy
        self.enforceBrowserPolicy = enforceBrowserPolicy
        self.enforceRemoteControlPolicy = enforceRemoteControlPolicy
        browserPolicyActive = isBrowserDisabledByPolicy()
        remoteControlPolicyActive = isRemoteControlDisabledByPolicy()
        observe(UserDefaults.didChangeNotification)
        observe(NSApplication.didBecomeActiveNotification)
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    private func observe(_ name: Notification.Name) {
        let center = notificationCenter
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: name) {
                guard let self else { break }
                self.reevaluate()
            }
        })
    }

    /// Compares the current policy state to the last-seen state and runs the
    /// matching enforcement on a transition. Exposed for tests and for the
    /// startup call after construction.
    func reevaluate() {
        let browserNow = isBrowserDisabledByPolicy()
        if browserNow != browserPolicyActive {
            browserPolicyActive = browserNow
            if browserNow {
                enforceBrowserPolicy()
            }
            // Both directions change the effective availability of gated UI.
            notificationCenter.post(
                name: BrowserAvailabilitySettings.didChangeNotification,
                object: nil
            )
        }
        let remoteNow = isRemoteControlDisabledByPolicy()
        if remoteNow != remoteControlPolicyActive {
            remoteControlPolicyActive = remoteNow
            // syncToSettings() handles both teardown and re-arming.
            enforceRemoteControlPolicy()
        }
    }
}
