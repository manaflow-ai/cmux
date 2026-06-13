#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation
import UIKit
import UserNotifications

/// Bridges APNs push between the app-target `AppDelegate` and the mobile shell
/// store: drives opt-in registration, hands device tokens to the injected
/// ``CmuxAuthRuntime/PushRegistrationService``, and routes foreground
/// presentation + taps to the active ``CMUXMobileShellStore`` for "mirror macOS"
/// suppression and deep-link.
///
/// The coordinator is the seam between the `UIApplicationDelegate` (which must
/// own `UNUserNotificationCenterDelegate`) and the per-scene store. Constructed
/// once at the composition root with an injected push-registration service and
/// injected into the SwiftUI environment + the app delegate; no singleton.
@MainActor
@Observable
public final class MobilePushCoordinator {
    private let registration: any PushRegistering
    private let analytics: any AnalyticsEmitting
    // UserDefaults is Apple-documented thread-safe; a synchronous read mirrors
    // the opt-in flag for the menu UI without awaiting the actor service.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let enabledKey = "cmux.notifications.pushEnabled"

    @ObservationIgnored private weak var store: CMUXMobileShellStore?

    /// A tap whose navigation could not complete yet. On a cold launch the
    /// notification-center delegate delivers the tap before the root view has
    /// mounted (no store bound yet), and even once bound the tapped workspace
    /// is not in the store until the Mac attach finishes. The tap is parked
    /// here and re-applied from ``bind(store:)`` and ``workspacesDidChange()``
    /// until the target exists or the request expires.
    private struct PendingDeeplink {
        let workspaceId: String?
        let surfaceId: String?
        let createdAt: Date
    }

    @ObservationIgnored private var pendingDeeplink: PendingDeeplink?
    /// Bounded so a tap from long ago cannot yank the user out of whatever
    /// they navigated to in the meantime, but generous enough to cover cold
    /// launch plus sign-in plus a slow attach.
    private static let pendingDeeplinkLifetime: TimeInterval = 120
    @ObservationIgnored private let now: () -> Date

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - analytics: The injected fire-and-forget analytics emitter. Defaults to
    ///     ``NoopAnalytics`` for previews/tests.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    ///   - now: Clock seam for the pending-deeplink expiry. Defaults to
    ///     `Date.init`.
    public init(
        registration: any PushRegistering,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.registration = registration
        self.analytics = analytics
        self.defaults = defaults
        self.now = now
    }

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
        applyPendingDeeplinkIfReady()
    }

    /// Re-apply a parked notification tap once its target can exist. Called by
    /// the root view whenever the store's workspace list changes (the list is
    /// empty until the Mac attach completes).
    public func workspacesDidChange() {
        applyPendingDeeplinkIfReady()
    }

    /// Install the notification-center delegate and, if already opted in,
    /// re-assert remote registration so a rotated token re-uploads. Call once at
    /// launch from the AppDelegate.
    public func configure(delegate: any UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
        if isEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Opt in: request system authorization, register for remote notifications,
    /// and persist the flag. Returns whether authorization was granted.
    @discardableResult
    public func enable() async -> Bool {
        let priorStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        // Only an undetermined status produces a real OS prompt; gate the
        // "shown" event on it so a re-toggle of an already-decided status does
        // not log a phantom prompt.
        if priorStatus == .notDetermined {
            analytics.capture("ios_push_optin_prompt_shown", [
                "trigger": .string("settings_toggle"),
                "prior_authorization_status": .string("not_determined"),
            ])
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            analytics.capture("ios_push_optin_declined", [
                "trigger": .string("settings_toggle"),
                "was_os_level_predenied": .bool(priorStatus == .denied),
            ])
            return false
        }
        analytics.capture("ios_push_optin_granted", ["trigger": .string("settings_toggle")])
        await registration.setEnabled(true)
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        await registration.setEnabled(false)
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        await registration.register(deviceToken: token)
    }

    /// Re-upload the cached token when possible (e.g. after sign-in).
    public func syncTokenIfPossible() async {
        await registration.syncTokenIfPossible()
    }

    /// Remove the cached token from the server (on sign-out), authenticating
    /// with the credentials captured before the local-first sign-out cleared
    /// the live token store.
    public func unregisterFromServer(accessToken: String?, refreshToken: String?) async {
        await registration.unregisterFromServer(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        guard let store, let workspaceId,
              store.selectedWorkspaceID?.rawValue == workspaceId else {
            return true
        }
        if let surfaceId {
            return store.selectedTerminalID?.rawValue != surfaceId
        }
        return false
    }

    /// Deep-link to the workspace/terminal a tapped notification refers to.
    ///
    /// The tap is parked first and applied through one path: a cold launch
    /// delivers the tap before the root view has bound a store, and a
    /// warm-but-detached app has not loaded the workspace yet. Navigating
    /// immediately in those states is what stranded users on the workspaces
    /// home screen.
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        pendingDeeplink = PendingDeeplink(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            createdAt: now()
        )
        applyPendingDeeplinkIfReady()
    }

    /// Apply the parked tap if its target can be navigated to right now;
    /// otherwise keep it parked for the next ``bind(store:)`` or
    /// ``workspacesDidChange()``.
    private func applyPendingDeeplinkIfReady() {
        guard let pending = pendingDeeplink else { return }
        guard now().timeIntervalSince(pending.createdAt) < Self.pendingDeeplinkLifetime else {
            pendingDeeplink = nil
            analytics.capture("ios_push_deeplink_failed", ["reason": .string("expired")])
            return
        }
        guard let store else { return }

        // Resolve the workspace to navigate to: the explicit target, or for a
        // surface-only tap the workspace that owns the terminal. Unresolvable
        // means "not loaded yet": stay parked for the next topology change so
        // the tap is never spent on a selection that cannot navigate.
        let workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            workspaceTarget = MobileWorkspacePreview.ID(rawValue: workspaceId)
            guard store.workspaces.contains(where: { $0.id == workspaceTarget }) else { return }
        } else if let surfaceId = pending.surfaceId {
            guard let owner = store.workspaceID(containingSurfaceID: surfaceId) else { return }
            workspaceTarget = owner
        } else {
            pendingDeeplink = nil
            return
        }

        if let surfaceId = pending.surfaceId,
           !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            // The workspace is here but its terminal snapshot is not (still
            // loading, or the terminal was closed). Land the user in the right
            // workspace now and keep only the surface part parked so it can
            // resolve if the terminal arrives, bounded by the same expiry.
            store.navigateToWorkspaceForDeeplink(workspaceTarget)
            pendingDeeplink = PendingDeeplink(
                workspaceId: nil,
                surfaceId: surfaceId,
                createdAt: pending.createdAt
            )
            return
        }

        store.navigateToWorkspaceForDeeplink(workspaceTarget)
        if let surfaceId = pending.surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        pendingDeeplink = nil
        analytics.capture("ios_push_deeplink_resolved", [
            "resolved_workspace": .bool(pending.workspaceId != nil),
            "resolved_surface": .bool(pending.surfaceId != nil),
        ])
    }
}
#endif
