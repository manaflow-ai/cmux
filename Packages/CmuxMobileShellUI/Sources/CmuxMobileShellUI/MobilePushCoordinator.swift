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

    /// The set of workspace ids muted for phone push, as an observation-tracked
    /// stored property so SwiftUI re-renders the workspace list when a row is
    /// muted/unmuted. Hydrated from the registration service at launch (the
    /// service owns the persisted source of truth) and kept in lock-step on
    /// every toggle. Unlike ``isEnabled`` (a deliberately non-observable
    /// `UserDefaults` mirror), this must be observable: the list's per-row mute
    /// indicator and context-menu label derive from it directly.
    public private(set) var mutedWorkspaceIDs: Set<String> = []

    /// The single in-flight server mute hydration, owned so it can be cancelled.
    /// Starting a new refresh or signing out cancels the prior one, so a stale
    /// fetch (e.g. one begun under a previous account whose tokens are briefly
    /// still valid during sign-out) can never write its result back. Using
    /// structured ownership + cancellation instead of a generation counter keeps
    /// exactly one authoritative refresh and avoids a stale task performing any
    /// destructive cleanup. `@ObservationIgnored`: it is lifecycle, not rendered.
    @ObservationIgnored private var mutedRefreshTask: Task<Void, Never>?

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - analytics: The injected fire-and-forget analytics emitter. Defaults to
    ///     ``NoopAnalytics`` for previews/tests.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    public init(
        registration: any PushRegistering,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        defaults: UserDefaults = .standard
    ) {
        self.registration = registration
        self.analytics = analytics
        self.defaults = defaults
    }

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Install the notification-center delegate and, if already opted in,
    /// re-assert remote registration so a rotated token re-uploads. Call once at
    /// launch from the AppDelegate.
    ///
    /// This never requests notification authorization: the OS prompt only ever
    /// fires from ``enable()`` (the explicit user opt-in), so a fresh launch on a
    /// phone that has not opted in shows no permission dialog.
    public func configure(delegate: any UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
        if isEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
        // Hydrate the observable muted set from the persisted source of truth so
        // the workspace list reflects prior mutes immediately on launch.
        Task { mutedWorkspaceIDs = await registration.mutedWorkspaceIDs }
    }

    /// Whether `workspaceId` is currently muted for phone push.
    public func isWorkspaceMuted(_ workspaceId: String) -> Bool {
        mutedWorkspaceIDs.contains(workspaceId)
    }

    /// Pull the authoritative muted set from the server and republish the
    /// observable from it. Call on sign-in: the server set is keyed by the
    /// authenticated user, so this overwrites any locally cached set from a
    /// previous account instead of re-uploading it. A network failure / signed
    /// out state keeps the existing local set (no clobber to empty).
    ///
    /// Owns a single cancellable refresh task: a new refresh or a sign-out
    /// cancels any prior one, and a cancelled fetch never writes its (stale)
    /// result back, so a refresh begun under a previous account can't repopulate
    /// the cache after sign-out.
    public func refreshMutedWorkspacesFromServer() {
        mutedRefreshTask?.cancel()
        mutedRefreshTask = Task { [weak self] in
            guard let self else { return }
            let serverSet = await self.registration.hydrateMutedWorkspacesFromServer()
            guard !Task.isCancelled else { return }
            self.mutedWorkspaceIDs = serverSet
        }
    }

    /// Set phone-push mute for a workspace to an explicit state. Updates the
    /// observable set optimistically (so the list re-renders at once), persists,
    /// and syncs the full muted set to the server, where delivery is actually
    /// gated. Honors the requested `muted` value rather than toggling, so a stale
    /// row snapshot or a state change while a context menu is open can never flip
    /// the workspace to the wrong state.
    public func setWorkspaceMuted(_ workspaceId: String, muted: Bool) {
        if muted == mutedWorkspaceIDs.contains(workspaceId) { return }
        if muted {
            mutedWorkspaceIDs.insert(workspaceId)
        } else {
            mutedWorkspaceIDs.remove(workspaceId)
        }
        analytics.capture("ios_push_workspace_mute_toggled", ["muted": .bool(muted)])
        Task {
            await registration.setWorkspaceMuted(workspaceId, muted: muted)
            // Reconcile against the persisted authoritative set in case a
            // concurrent change interleaved.
            mutedWorkspaceIDs = await registration.mutedWorkspaceIDs
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

    /// Remove the cached token from the server (on sign-out).
    public func unregisterFromServer() async {
        await registration.unregisterFromServer()
    }

    /// Sign-out cleanup: clear the locally cached muted set + observable FIRST,
    /// then remove the token server-side. The local clear must run before the
    /// network unregister because this hook runs inside `AuthCoordinator.signOut`'s
    /// bounded, cancellable teardown task: if the DELETE is slow the task can be
    /// cancelled at its deadline, and we still must not leak this account's mutes
    /// to the next signed-in user. Does not touch the signed-out user's server
    /// mute rows (those are theirs to keep).
    public func handleSignedOut() async {
        // Cancel any in-flight server hydration FIRST so a stale refresh (still
        // using the prior account's briefly-valid tokens) cannot write the prior
        // user's mutes back after this clear. A cancelled task returns without
        // touching the cache.
        mutedRefreshTask?.cancel()
        mutedRefreshTask = nil
        mutedWorkspaceIDs = []
        await registration.clearLocalMutedWorkspaces()
        await registration.unregisterFromServer()
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// workspace is muted, or when the user is already viewing the terminal the
    /// notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        // Honor the per-workspace mute locally too: the server is the primary
        // gate, but a push can already be in flight when the mute PUT lands, or
        // the server can fail open on a mute-lookup error, so a muted workspace
        // must never surface a foreground banner/sound. Mirrors the server's
        // `shouldDeliverToWorkspace`.
        guard PushMutePolicy.shouldDeliver(workspaceId: workspaceId, muted: mutedWorkspaceIDs) else {
            return false
        }
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
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        guard let store else {
            analytics.capture("ios_push_deeplink_failed", ["reason": .string("no_store")])
            return
        }
        if let workspaceId {
            store.selectedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceId)
        }
        if let surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        analytics.capture("ios_push_deeplink_resolved", [
            "resolved_workspace": .bool(workspaceId != nil),
            "resolved_surface": .bool(surfaceId != nil),
        ])
    }
}
#endif
