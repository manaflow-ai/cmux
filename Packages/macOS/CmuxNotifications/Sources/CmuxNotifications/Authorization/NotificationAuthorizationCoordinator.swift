import Foundation
import UserNotifications
import os

#if DEBUG
import CMUXDebugLog
#endif

/// Logs to the same `com.cmuxterm.app` / `notification` channel the app target's
/// notification store uses, so the relocated authorization lifecycle keeps an
/// identical log signature.
nonisolated private let notificationAuthorizationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification"
)

/// Owns the cmux notification authorization lifecycle: querying the system
/// authorization status, issuing the system permission request (manually from
/// Settings or automatically while delivering a notification), and the
/// gating/deferral rules around the automatic request.
///
/// Relocated verbatim from the app target's notification store. The store still
/// owns the AppKit "enable notifications" settings prompt and the
/// `UNUserNotificationCenter` delivery/clearing paths; this coordinator reaches
/// the app-side pieces through three constructor seams so no AppKit, app-focus,
/// or localization concern leaks into the package:
///
/// - ``isAppActive`` mirrors `AppFocusState.isAppActive()`.
/// - ``cachedDeliveryDecision`` is the store's pure delivery-time decision
///   (`cachedDeliveryAuthorizationDecision(for:isAppActive:)`).
/// - ``presentSettingsPrompt`` shows the app-side AppKit settings alert, whose
///   localized strings stay in the app target.
///
/// Isolation: `@MainActor`, matching the store the logic came from. The
/// `UNUserNotificationCenter` completion handlers fire off-main, so each hops
/// back with `DispatchQueue.main.async` + `MainActor.assumeIsolated` exactly
/// where the original used `DispatchQueue.main.async`, copying the only
/// `Sendable` values it needs (the `UNAuthorizationStatus` / error description)
/// before the hop so no non-`Sendable` system object crosses the boundary.
@MainActor
public final class NotificationAuthorizationCoordinator {
    /// The app's view of the system notification authorization status, refreshed
    /// from `UNUserNotificationCenter` whenever the lifecycle queries it.
    public private(set) var authorizationState: NotificationAuthorizationState = .unknown

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false

    private let isAppActive: () -> Bool
    private let cachedDeliveryDecision: (NotificationAuthorizationState, Bool) -> Bool?
    private let presentSettingsPrompt: () -> Void

    /// Creates the coordinator with the app-side seams it forwards to.
    ///
    /// - Parameters:
    ///   - isAppActive: Whether the app is currently active, used to defer an
    ///     automatic request raised while the app is in the background.
    ///   - cachedDeliveryDecision: The store's pure delivery-time short-circuit:
    ///     `nil` means "query the system", a non-`nil` value is the decision to
    ///     use without prompting, given the current state and app-active flag.
    ///   - presentSettingsPrompt: Shows the app-side AppKit settings prompt when
    ///     a non-delivery request finds notifications denied.
    public init(
        isAppActive: @escaping () -> Bool,
        cachedDeliveryDecision: @escaping (NotificationAuthorizationState, Bool) -> Bool?,
        presentSettingsPrompt: @escaping () -> Void
    ) {
        self.isAppActive = isAppActive
        self.cachedDeliveryDecision = cachedDeliveryDecision
        self.presentSettingsPrompt = presentSettingsPrompt
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        logDebugEvent("notification.auth \(message)")
#endif
        notificationAuthorizationLogger.info("Authorization \(message, privacy: .private)")
    }

    /// Re-queries the system authorization status and republishes it.
    public func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.authorizationState = NotificationAuthorizationState(authorizationStatus: status)
                    self.logAuthorization(
                        "refresh status=\(status.diagnosticLabel) mapped=\(self.authorizationState.statusLabel)"
                    )
                }
            }
        }
    }

    /// Handles the Settings authorization button: a manual request that always
    /// proceeds to the system prompt when the status allows it.
    public func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _, _ in }
    }

    /// Re-runs a deferred authorization request when the app becomes active, or
    /// otherwise refreshes the cached status.
    public func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _, _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    /// Resolves whether notifications may be delivered for `origin`, requesting
    /// or deferring system authorization as needed, then calls `completion` with
    /// the decision and the effective authorization state behind it.
    ///
    /// `completion` receives the decision plus the effective authorization
    /// state behind it. The state matters for the just-prompted-and-declined
    /// case: `authorizationState` is refreshed asynchronously there, so a
    /// caller reading the property would still see `.notDetermined` and play
    /// the fallback sound for the very notification whose prompt the user
    /// just denied.
    public func ensureAuthorization(
        origin: NotificationAuthorizationRequestOrigin,
        _ completion: @escaping @MainActor @Sendable (Bool, NotificationAuthorizationState) -> Void
    ) {
        if origin == .notificationDelivery,
           let cachedDecision = cachedDeliveryDecision(authorizationState, isAppActive()) {
            if !cachedDecision, authorizationState == .notDetermined {
                hasDeferredAuthorizationRequest = true
            }
            completion(cachedDecision, authorizationState)
            return
        }

        logAuthorization("ensure start origin=\(origin.rawValue)")
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        completion(false, .unknown)
                        return
                    }

                    self.authorizationState = NotificationAuthorizationState(authorizationStatus: status)
                    self.logAuthorization(
                        "ensure status origin=\(origin.rawValue) status=\(status.diagnosticLabel) mapped=\(self.authorizationState.statusLabel) appActive=\(self.isAppActive())"
                    )
                    switch status {
                    case .authorized, .provisional, .ephemeral:
                        completion(true, self.authorizationState)
                    case .denied:
                        if origin != .notificationDelivery {
                            self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                            self.presentSettingsPrompt()
                        }
                        completion(false, .denied)
                    case .notDetermined:
                        if Self.shouldDeferAutomaticAuthorizationRequest(
                            origin: origin,
                            status: status,
                            isAppActive: self.isAppActive()
                        ) {
                            self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                            self.hasDeferredAuthorizationRequest = true
                            completion(false, .notDetermined)
                        } else {
                            self.requestAuthorizationIfNeeded(origin: origin, completion)
                        }
                    @unknown default:
                        self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                        completion(false, .unknown)
                    }
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: NotificationAuthorizationRequestOrigin,
        _ completion: @escaping @MainActor @Sendable (Bool, NotificationAuthorizationState) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard NotificationAuthorizationRequestGate(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ).shouldRequestAuthorization else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false, authorizationState)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            let errorDescription = error?.localizedDescription
            let hadError = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if granted {
                        self.authorizationState = .authorized
                    } else {
                        self.refreshAuthorizationStatus()
                    }
                    self.logAuthorization(
                        "request callback origin=\(origin.rawValue) granted=\(granted) error=\(errorDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                    )
                    // A non-grant without an error is the user answering the
                    // prompt with a live denial, even while authorizationState is
                    // still refreshing. A request error is not a user decision,
                    // so it reports .unknown and the fallback sound stays on
                    // (fail-open).
                    let effectiveState: NotificationAuthorizationState =
                        granted ? .authorized : (hadError ? .unknown : .denied)
                    completion(granted, effectiveState)
                }
            }
        }
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: NotificationAuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return status.shouldDeferAutomaticAuthorizationRequest(isAppActive: isAppActive)
    }
}
