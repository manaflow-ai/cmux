import AppKit
import CmuxSettings
import Foundation
import Observation

/// Applies MDM managed-policy transitions to a running app.
///
/// When the embedded-browser policy activates it runs the injected browser
/// enforcement (closing live browser panes) and posts
/// `BrowserAvailabilitySettings.didChangeNotification` so gated UI refreshes;
/// when the remote-control policy flips either way it runs the injected
/// mobile enforcement (`MobileHostService.syncToSettings()`, which tears the
/// host down or re-arms it). Every transition also posts
/// `ManagedDevicePolicy.didChangeNotification` so Settings UI re-reads the
/// resolver.
///
/// Managed-preference pushes do not reliably fire
/// `UserDefaults.didChangeNotification`, so the observer also re-evaluates on
/// app activation and on a periodic cadence (``recheckInterval``) — an MDM
/// push against a Mac that stays frontmost is enforced within one interval,
/// not only at the next activation.
@MainActor
@Observable
final class ManagedPolicyEnforcementObserver {
    /// Upper bound on enforcement latency for out-of-band MDM pushes that
    /// fire no local notification. Justified periodic re-check: there is no
    /// callback API for managed-preference changes, and an enforcement
    /// deadline is the intended behavior (matches MDM check-in semantics).
    static let recheckInterval: Duration = .seconds(60)
    private(set) var isBrowserEnabled: Bool
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let isBrowserDisabledByPolicy: () -> Bool
    @ObservationIgnored private let readBrowserEnabled: () -> Bool
    @ObservationIgnored private let onBrowserAvailabilityChange: (Bool) -> Void
    @ObservationIgnored private let browserURLAllowlistPolicy: () -> BrowserURLAllowlistPolicy
    @ObservationIgnored private let isRemoteControlDisabledByPolicy: () -> Bool
    @ObservationIgnored private let enforceBrowserPolicy: () -> Void
    @ObservationIgnored private let enforceBrowserURLAllowlistPolicy: () -> Void
    @ObservationIgnored private let enforceRemoteControlPolicy: () -> Void
    @ObservationIgnored private var browserPolicyActive: Bool
    @ObservationIgnored private var observedBrowserURLAllowlistPolicy: BrowserURLAllowlistPolicy
    @ObservationIgnored private var remoteControlPolicyActive: Bool
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(
        notificationCenter: NotificationCenter = .default,
        isBrowserDisabledByPolicy: @escaping () -> Bool = {
            BrowserAvailabilitySettings.isManagedByPolicy
        },
        readBrowserEnabled: @escaping () -> Bool = {
            BrowserAvailabilitySettings.isEnabled()
        },
        onBrowserAvailabilityChange: @escaping (Bool) -> Void = { _ in },
        browserURLAllowlistPolicy: @escaping () -> BrowserURLAllowlistPolicy = {
            BrowserURLAllowlistPolicy(defaults: .standard)
        },
        isRemoteControlDisabledByPolicy: @escaping () -> Bool = {
            MobileRemoteControlPolicy.isDisabled
        },
        enforceBrowserPolicy: @escaping () -> Void,
        enforceBrowserURLAllowlistPolicy: @escaping () -> Void,
        enforceRemoteControlPolicy: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.isBrowserDisabledByPolicy = isBrowserDisabledByPolicy
        self.readBrowserEnabled = readBrowserEnabled
        self.onBrowserAvailabilityChange = onBrowserAvailabilityChange
        self.browserURLAllowlistPolicy = browserURLAllowlistPolicy
        self.isRemoteControlDisabledByPolicy = isRemoteControlDisabledByPolicy
        self.enforceBrowserPolicy = enforceBrowserPolicy
        self.enforceBrowserURLAllowlistPolicy = enforceBrowserURLAllowlistPolicy
        self.enforceRemoteControlPolicy = enforceRemoteControlPolicy
        browserPolicyActive = isBrowserDisabledByPolicy()
        isBrowserEnabled = readBrowserEnabled()
        observedBrowserURLAllowlistPolicy = browserURLAllowlistPolicy()
        remoteControlPolicyActive = isRemoteControlDisabledByPolicy()
        observe(UserDefaults.didChangeNotification)
        observe(NSApplication.didBecomeActiveNotification)
        observationTasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.recheckInterval)
                } catch {
                    break
                }
                guard let self else { break }
                self.reevaluate()
            }
        })
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
        var anyTransition = false
        let browserNow = isBrowserDisabledByPolicy()
        if browserNow != browserPolicyActive {
            browserPolicyActive = browserNow
            anyTransition = true
            if browserNow {
                enforceBrowserPolicy()
            }
            // Both directions change the effective availability of gated UI.
            notificationCenter.post(
                name: BrowserAvailabilitySettings.didChangeNotification,
                object: nil
            )
        }
        let browserEnabledNow = readBrowserEnabled()
        if browserEnabledNow != isBrowserEnabled {
            isBrowserEnabled = browserEnabledNow
            onBrowserAvailabilityChange(browserEnabledNow)
            notificationCenter.post(
                name: BrowserAvailabilitySettings.effectiveStateDidChangeNotification,
                object: nil
            )
        }
        let browserURLAllowlistNow = browserURLAllowlistPolicy()
        if browserURLAllowlistNow != observedBrowserURLAllowlistPolicy {
            observedBrowserURLAllowlistPolicy = browserURLAllowlistNow
            anyTransition = true
            enforceBrowserURLAllowlistPolicy()
        }
        let remoteNow = isRemoteControlDisabledByPolicy()
        if remoteNow != remoteControlPolicyActive {
            remoteControlPolicyActive = remoteNow
            anyTransition = true
            // syncToSettings() handles both teardown and re-arming.
            enforceRemoteControlPolicy()
        }
        if anyTransition {
            // Settings UI re-reads the resolver on this signal.
            notificationCenter.post(
                name: ManagedDevicePolicy.didChangeNotification,
                object: nil
            )
        }
    }
}
