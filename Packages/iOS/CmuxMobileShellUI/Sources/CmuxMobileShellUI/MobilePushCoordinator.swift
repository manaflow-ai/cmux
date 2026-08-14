#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let mobilePushLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "push"
)

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
    private let diagnosticLog: DiagnosticLog?
    /// The system-notification surface used by the cold dismiss lane. Owned here
    /// (not via the store) because a silent dismiss push can wake the app in the
    /// background before any scene — and therefore any store — exists.
    private let deliveredNotificationClearer: any DeliveredNotificationClearing
    /// Durable phone→Mac dismiss outbox for swipes that arrive before any shell
    /// store exists (a background launch from Notification Center). Backed by
    /// the same `UserDefaults` key the store's own queue uses, so the store's
    /// flush-on-subscribe delivers these too.
    @ObservationIgnored private let pendingDismissQueue: PendingNotificationDismissQueue
    // UserDefaults is Apple-documented thread-safe; a synchronous read mirrors
    // the opt-in flag for the menu UI without awaiting the actor service.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let enabledKey = "cmux.notifications.pushEnabled"
    private var enabledMirror: Bool

    /// Base APNs `aps.category` the web sets on non-replyable cmux terminal
    /// pushes (see `CMUX_APNS_CATEGORY` in `web/services/apns/payload.ts`). The
    /// matching ``UNNotificationCategory`` registered below carries
    /// `.customDismissAction`, so a swipe/clear delivers
    /// `UNNotificationDismissActionIdentifier` to the app and we can forward the
    /// dismiss to the Mac. Keep these two ids in sync.
    public static let dismissSyncCategoryIdentifier = "cmux.terminal"
    /// APNs category for terminal notifications that accept text input.
    public static let replyCategoryIdentifier = "cmux.terminal.reply"
    /// Notification action identifier delivered for a submitted inline reply.
    public static let replyActionIdentifier = "cmux.reply"

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
        let macDeviceId: String?
        let retargetsToLiveSurfaceOwner: Bool
        let createdAt: Date
        let lastNavigatedWorkspaceId: MobileWorkspacePreview.ID?
    }

    @ObservationIgnored private var pendingDeeplink: PendingDeeplink?
    /// Bounded so a tap from long ago cannot yank the user out of whatever
    /// they navigated to in the meantime, but generous enough to cover cold
    /// launch plus sign-in plus a slow attach.
    private static let pendingDeeplinkLifetime: TimeInterval = 120
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pendingReplyState = PendingReplyState()
    @ObservationIgnored private var replySendInFlight = false
    /// One-shot delayed re-evaluation armed after a FAILED reply send: a
    /// transient RPC failure with unchanged topology fires no store/channel
    /// event, so without this the re-parked reply would sit until its 120 s
    /// lifetime dropped it. Each retry re-arms on failure, so attempts stay
    /// bounded by the reply lifetime; success or a fresh park cancels it.
    @ObservationIgnored private var replyRetryTask: Task<Void, Never>?
    @ObservationIgnored private let replyRetrySleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let settingsMutationSleep:
        @Sendable (Duration) async throws -> Void
    private static let replyRetryDelay: Duration = .seconds(5)
    /// Authorization prompts and backend reconciliation must not hold the
    /// app-lifetime settings slot forever. The sleep is injected for
    /// deterministic timeout tests.
    private static let settingsMutationTimeout: Duration = .seconds(30)
    /// The iOS API endpoint that accepted this installation's APNs token.
    public let phoneAPIOrigin: String
    /// Live OS authorization, refreshed at launch, on foreground, and when
    /// Settings opens or performs a repair.
    public private(set) var authorization: MobilePushAuthorization = .notDetermined
    /// Live independent iOS presentation policies. Authorization alone is not
    /// enough to promise a visible, audible, timely banner.
    public private(set) var systemSettings = MobilePushSystemSettings
        .authorizationOnly(.notDetermined)
    /// Local/APNs/backend registration stage streamed from the actor service.
    public private(set) var registrationSnapshot: PushRegistrationSnapshot = .disabled
    @ObservationIgnored private let notificationSettings:
        @MainActor () async -> MobilePushSystemSettings
    @ObservationIgnored private let requestAuthorization:
        @MainActor () async -> Bool
    @ObservationIgnored private let registerForRemoteNotifications:
        @MainActor () -> Void
    @ObservationIgnored private let unregisterForRemoteNotifications:
        @MainActor () -> Void
    @ObservationIgnored private var registrationSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var registrationRecoveryTask:
        Task<PushRegistrationSnapshot, Never>?
    @ObservationIgnored private var registrationRecoveryToken: UUID?
    /// Settings owns the user intent, while the registration service owns the
    /// network side effect. This task is app-lifetime state, not view-lifetime
    /// state, and a newer intent cancels the coordinator work without waiting
    /// for the old task to unwind.
    @ObservationIgnored private var settingsMutationTask: Task<Bool, Never>?
    @ObservationIgnored private var settingsMutationWorkers:
        MobilePushMutationWorkers?
    @ObservationIgnored private var settingsMutationToken = UUID()
    @ObservationIgnored private var settingsMutationNeedsRetry = false
    @ObservationIgnored private var registrationIntentGeneration: UInt64 = 0
    @ObservationIgnored private var workspaceAuthorizationRequestInFlight = false
    @ObservationIgnored private var hasRequestedRemoteRegistration = false

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - analytics: The injected fire-and-forget analytics emitter. Defaults to
    ///     ``NoopAnalytics`` for previews/tests.
    ///   - diagnosticLog: The app-root privacy-safe diagnostics recorder.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    ///   - deliveredNotificationClearer: The system-notification seam used to
    ///     remove banners for a background dismiss push. Defaults to the real
    ///     `UNUserNotificationCenter`-backed conformance.
    ///   - pendingDismissQueue: The durable phone→Mac dismiss outbox shared (via
    ///     `UserDefaults`) with the shell store, used when a swipe arrives before
    ///     any store exists. Defaults to the standard-defaults-backed queue.
    ///   - now: Clock seam for pending deep-link and inline-reply expiry. Defaults
    ///     to `Date.init`.
    public init(
        registration: any PushRegistering,
        analytics: any AnalyticsEmitting = NoopAnalytics(),
        diagnosticLog: DiagnosticLog? = nil,
        phoneAPIOrigin: String = "https://cmux.com",
        defaults: UserDefaults = .standard,
        deliveredNotificationClearer: any DeliveredNotificationClearing = SystemDeliveredNotificationClearer(),
        pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(),
        now: @escaping () -> Date = Date.init,
        authorizationStatus: (@MainActor () async -> UNAuthorizationStatus)? = nil,
        notificationSettings: (@MainActor () async -> MobilePushSystemSettings)? = nil,
        requestAuthorization: @escaping @MainActor () async -> Bool = {
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        },
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        unregisterForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.unregisterForRemoteNotifications()
        },
        replyRetrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        },
        settingsMutationSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.registration = registration
        self.replyRetrySleep = replyRetrySleep
        self.settingsMutationSleep = settingsMutationSleep
        self.analytics = analytics
        self.diagnosticLog = diagnosticLog
        self.phoneAPIOrigin = phoneAPIOrigin
        self.defaults = defaults
        self.enabledMirror = defaults.bool(forKey: Self.enabledKey)
        self.deliveredNotificationClearer = deliveredNotificationClearer
        self.pendingDismissQueue = pendingDismissQueue
        self.now = now
        if let notificationSettings {
            self.notificationSettings = notificationSettings
        } else if let authorizationStatus {
            self.notificationSettings = {
                .authorizationOnly(
                    Self.authorization(from: await authorizationStatus())
                )
            }
        } else {
            self.notificationSettings = {
                Self.systemSettings(
                    from: await UNUserNotificationCenter.current()
                        .notificationSettings()
                )
            }
        }
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications = unregisterForRemoteNotifications
    }

    /// Whether the user has opted into phone notifications.
    ///
    /// This is an app-lifetime observable mirror, rather than a view-local
    /// value. Settings can therefore render the requested value before the
    /// backend cleanup finishes.
    public var isEnabled: Bool { enabledMirror }

    /// Apply a Settings preference immediately and finish its registration work
    /// from the app-lifetime coordinator. A newer intent cancels the old
    /// coordinator task and starts independently, so an opt-out can preempt an
    /// authorization prompt or other suspended enable path.
    public func setEnabledIntent(_ enabled: Bool) {
        guard enabled != enabledMirror || settingsMutationNeedsRetry else {
            return
        }
        let intent = beginSettingsIntent(enabled)
        _ = startSettingsMutation(token: intent.token) { [weak self] in
            guard let self else { return false }
            if enabled {
                return await self.enable(
                    trigger: "settings_toggle",
                    settingsMutationToken: intent.token,
                    registrationGeneration: intent.registrationGeneration
                )
            }
            await self.finishDisable(
                settingsMutationToken: intent.token,
                registrationGeneration: intent.registrationGeneration
            )
            return self.isCurrentSettingsMutation(intent.token)
        }
    }

    /// Starts the one app-lifetime worker used by every settings/reconciliation
    /// entry point. The returned task is independent from the caller's waiter;
    /// a newer intent cancels it through `settingsMutationTask`.
    @discardableResult
    private func startSettingsMutation(
        token: UUID,
        operation: @escaping @MainActor () async -> Bool
    ) -> Task<Bool, Never> {
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let result = await self.runSettingsMutation(
                token: token,
                operation: operation
            )
            self.finishSettingsMutation(token)
            return result
        }
        settingsMutationTask = task
        return task
    }

    /// Runs a settings mutation with an independent deadline. The operation
    /// remains app-lifetime work until the deadline, while a timed-out waiter
    /// is cancelled and the coordinator immediately exposes a retryable state.
    private func runSettingsMutation(
        token: UUID,
        operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let completion = MobilePushMutationCompletion()
        let operationTask = Task { @MainActor in
            let succeeded = await operation()
            await completion.resolve(.completed, succeeded: succeeded)
        }
        let timeoutTask = Task { [settingsMutationSleep] in
            do {
                try await settingsMutationSleep(Self.settingsMutationTimeout)
                await completion.resolve(.timedOut)
            } catch {
                // The mutation completed first and cancelled this sleeper.
            }
        }
        settingsMutationWorkers = MobilePushMutationWorkers(
            operation: operationTask,
            timeout: timeoutTask,
            completion: completion
        )
        let result = await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task { await completion.resolve(.cancelled) }
        }
        if settingsMutationWorkers?.completion === completion {
            settingsMutationWorkers = nil
        }
        timeoutTask.cancel()
        guard result.outcome == .timedOut else {
            return result.outcome == .completed && result.succeeded
        }
        operationTask.cancel()
        handleSettingsMutationTimeout(token)
        return false
    }

    private func handleSettingsMutationTimeout(_ token: UUID) {
        guard isCurrentSettingsMutation(token) else { return }
        settingsMutationTask = nil
        settingsMutationToken = UUID()
        settingsMutationNeedsRetry = true
        if enabledMirror {
            registrationSnapshot = PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: registrationSnapshot.hasDeviceToken,
                backendState: .failed(.networkUnavailable)
            )
            diagnosticLog?.recordAppEvent(
                .pushBackendSyncFailed,
                failure: .offline
            )
            analytics.capture("ios_push_settings_timeout", [
                "timeout_seconds": .int(
                    Int(Self.settingsMutationTimeout.components.seconds)
                ),
            ])
        }
    }

    /// Starts a new app-lifetime preference intent and invalidates every older
    /// lifecycle reconciliation. The returned generation must be checked after
    /// each suspension before an operation publishes or persists state.
    @discardableResult
    private func beginSettingsIntent(_ enabled: Bool) -> MobilePushSettingsIntent {
        cancelSettingsMutation()
        settingsMutationNeedsRetry = false
        let token = UUID()
        registrationIntentGeneration &+= 1
        settingsMutationToken = token
        if enabled {
            persistEnabledIntent()
        } else {
            prepareDisable()
        }
        return MobilePushSettingsIntent(
            token: token,
            registrationGeneration: registrationIntentGeneration
        )
    }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
        applyPendingDeeplinkIfReady()
        Task { @MainActor [weak self] in
            await self?.applyPendingReplyIfReady()
        }
    }

    /// Re-apply a parked notification tap once its target can exist. Called by
    /// the root view whenever the store's workspace list changes (the list is
    /// empty until the Mac attach completes).
    public func workspacesDidChange() {
        applyPendingDeeplinkIfReady()
        Task { @MainActor [weak self] in
            await self?.applyPendingReplyIfReady()
        }
    }

    /// Install the notification-center delegate and the terminal notification
    /// categories (dismiss-sync + inline reply), then start live readiness
    /// observation. The workspace/foreground lifecycle requests APNs
    /// registration after system authorization permits delivery. Call once at
    /// launch from the AppDelegate.
    public func configure(delegate: any UNUserNotificationCenterDelegate) {
        diagnosticLog?.recordAppEvent(.pushConfigured)
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // The category must carry `.customDismissAction` so a swipe/clear of a
        // cmux banner delivers `UNNotificationDismissActionIdentifier` to the
        // delegate; that is what lets us tell the Mac the user dismissed it.
        let dismissSyncCategory = UNNotificationCategory(
            identifier: Self.dismissSyncCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: String(localized: "mobile.push.reply.action", defaultValue: "Reply", bundle: .module),
            options: [],
            textInputButtonTitle: String(localized: "mobile.push.reply.send", defaultValue: "Send", bundle: .module),
            textInputPlaceholder: String(
                localized: "mobile.push.reply.placeholder",
                defaultValue: "Message the agent…",
                bundle: .module
            )
        )
        let replyCategory = UNNotificationCategory(
            identifier: Self.replyCategoryIdentifier,
            actions: [replyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([dismissSyncCategory, replyCategory])
        startRegistrationSnapshotObservation()
        Task { await refreshReadiness() }
    }

    /// Opt in: request system authorization, register for remote notifications,
    /// and persist the flag. Returns whether authorization was granted.
    @discardableResult
    public func enable() async -> Bool {
        let intent = beginSettingsIntent(true)
        let operation = startSettingsMutation(token: intent.token) { [weak self] in
            guard let self else { return false }
            return await self.enable(
                trigger: "settings_toggle",
                settingsMutationToken: intent.token,
                registrationGeneration: intent.registrationGeneration
            )
        }
        return await operation.value
    }

    /// Requests or recovers push only after the authenticated workspace shell
    /// is mounted. An explicit app opt-out remains authoritative.
    public func workspaceListDidBecomeVisible() async {
        // A Settings intent is the freshest user decision. Do not let the
        // workspace lifecycle reconcile an older persisted value while its
        // backend mutation is still draining.
        guard settingsMutationTask == nil else { return }
        if defaults.object(forKey: Self.enabledKey) as? Bool == false {
            return
        }
        let intentToken = settingsMutationToken
        let intentGeneration = registrationIntentGeneration
        let operation = startSettingsMutation(token: intentToken) { [weak self] in
            guard let self else { return false }
            return await self.reconcileWorkspaceListDidBecomeVisible(
                settingsMutationToken: intentToken,
                registrationGeneration: intentGeneration
            )
        }
        _ = await operation.value
    }

    private func reconcileWorkspaceListDidBecomeVisible(
        settingsMutationToken: UUID,
        registrationGeneration: UInt64
    ) async -> Bool {
        let settings = await notificationSettings()
        guard isCurrentSettingsMutation(settingsMutationToken) else {
            return false
        }
        apply(settings: settings)
        switch settings.authorization {
        case .authorized, .provisional, .ephemeral:
            guard isCurrentSettingsMutation(settingsMutationToken) else {
                return false
            }
            persistEnabledIntent()
            await activateRegistrationIfNeeded(
                settingsMutationToken: settingsMutationToken,
                registrationGeneration: registrationGeneration
            )
            await recoverRegistrationIfNeeded(
                settingsMutationToken: settingsMutationToken
            )
            return isCurrentSettingsMutation(settingsMutationToken)
        case .denied:
            // Preserve intent so Settings can explain the blocked OS gate and
            // a later foreground return can recover without another app launch.
            guard isCurrentSettingsMutation(settingsMutationToken) else {
                return false
            }
            persistEnabledIntent()
            return true
        case .notDetermined:
            guard !workspaceAuthorizationRequestInFlight else {
                return false
            }
            workspaceAuthorizationRequestInFlight = true
            defer { workspaceAuthorizationRequestInFlight = false }
            return await enable(
                trigger: "workspace_list",
                settingsMutationToken: settingsMutationToken,
                registrationGeneration: registrationGeneration
            )
        case .unsupported:
            return true
        }
    }

    private func enable(
        trigger: String,
        settingsMutationToken: UUID,
        registrationGeneration: UInt64
    ) async -> Bool {
        guard isCurrentSettingsMutation(settingsMutationToken),
              enabledMirror else {
            return false
        }
        let priorSettings = await notificationSettings()
        guard isCurrentSettingsMutation(settingsMutationToken),
              enabledMirror else {
            return false
        }
        apply(settings: priorSettings)
        let priorStatus = priorSettings.authorization
        persistEnabledIntent()
        // Only an undetermined status produces a real OS prompt; gate the
        // "shown" event on it so a re-toggle of an already-decided status does
        // not log a phantom prompt.
        if priorStatus == .notDetermined {
            diagnosticLog?.recordAppEvent(.pushAuthorizationPrompted)
            analytics.capture("ios_push_optin_prompt_shown", [
                "trigger": .string(trigger),
                "prior_authorization_status": .string("not_determined"),
            ])
        }
        let granted: Bool
        switch priorStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        case .notDetermined:
            granted = await requestAuthorization()
        case .denied, .unsupported:
            granted = false
        }
        guard isCurrentSettingsMutation(settingsMutationToken),
              enabledMirror else {
            // A system authorization prompt is user interaction and may outlive
            // the reconciliation deadline. If it eventually grants after that
            // deadline, start a fresh, current-generation reconciliation rather
            // than leaving the persisted opt-in without a service mutation.
            if enabledMirror, settingsMutationNeedsRetry {
                setEnabledIntent(true)
            }
            return false
        }
        guard granted else {
            // Authorization is an independent OS gate. The app intent still
            // has to reach the service so it can supersede an older disable
            // that may be suspended in cleanup; readiness remains blocked by
            // the denied/unsupported system status below.
            await registration.applyEnabledIntent(
                true,
                generation: registrationGeneration
            )
            guard isCurrentSettingsMutation(settingsMutationToken),
                  enabledMirror else {
                return false
            }
            await refreshReadiness(settingsMutationToken: settingsMutationToken)
            diagnosticLog?.recordAppEvent(.pushAuthorizationDenied)
            analytics.capture("ios_push_optin_declined", [
                "trigger": .string(trigger),
                "was_os_level_predenied": .bool(priorStatus == .denied),
            ])
            return false
        }
        if priorStatus == .notDetermined {
            let currentSettings = await notificationSettings()
            guard isCurrentSettingsMutation(settingsMutationToken),
                  enabledMirror else {
                return false
            }
            apply(settings: currentSettings)
        }
        diagnosticLog?.recordAppEvent(.pushAuthorizationGranted)
        analytics.capture("ios_push_optin_granted", ["trigger": .string(trigger)])
        await activateRegistrationIfNeeded(
            settingsMutationToken: settingsMutationToken,
            registrationGeneration: registrationGeneration
        )
        guard isCurrentSettingsMutation(settingsMutationToken),
              enabledMirror else {
            return false
        }
        await recoverRegistrationIfNeeded(settingsMutationToken: settingsMutationToken)
        return isCurrentSettingsMutation(settingsMutationToken)
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        let intent = beginSettingsIntent(false)
        let operation = startSettingsMutation(token: intent.token) { [weak self] in
            guard let self else { return false }
            await self.finishDisable(
                settingsMutationToken: intent.token,
                registrationGeneration: intent.registrationGeneration
            )
            return self.isCurrentSettingsMutation(intent.token)
        }
        _ = await operation.value
    }

    private func cancelSettingsMutation() {
        settingsMutationTask?.cancel()
        settingsMutationTask = nil
        settingsMutationWorkers?.operation.cancel()
        settingsMutationWorkers?.timeout.cancel()
        if let completion = settingsMutationWorkers?.completion {
            Task { await completion.resolve(.cancelled) }
        }
        settingsMutationWorkers = nil
        settingsMutationToken = UUID()
    }

    private func finishSettingsMutation(_ token: UUID) {
        guard settingsMutationToken == token else { return }
        settingsMutationTask = nil
    }

    private func prepareDisable() {
        diagnosticLog?.recordAppEvent(.pushDisabled)
        enabledMirror = false
        defaults.set(false, forKey: Self.enabledKey)
        registrationSnapshot = .disabled
        hasRequestedRemoteRegistration = false
        registrationRecoveryTask?.cancel()
        registrationRecoveryTask = nil
        registrationRecoveryToken = nil
        unregisterForRemoteNotifications()
    }

    private func finishDisable(
        settingsMutationToken: UUID,
        registrationGeneration: UInt64
    ) async {
        guard isCurrentSettingsMutation(settingsMutationToken), !enabledMirror else {
            return
        }
        await registration.applyEnabledIntent(
            false,
            generation: registrationGeneration
        )
        guard isCurrentSettingsMutation(settingsMutationToken), !enabledMirror else {
            return
        }
        let snapshot = await registration.snapshot
        guard isCurrentSettingsMutation(settingsMutationToken), !enabledMirror else {
            return
        }
        registrationSnapshot = snapshot
    }

    private func isCurrentSettingsMutation(_ token: UUID) -> Bool {
        // Task cancellation belongs to the caller's waiter. Preference
        // mutations live at app scope, and only a newer token supersedes them.
        return settingsMutationToken == token
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        diagnosticLog?.recordAppEvent(.pushDeviceTokenReceived, count: token.count)
        diagnosticLog?.recordAppEvent(.pushBackendSyncStarted)
        await registration.register(deviceToken: token)
        registrationSnapshot = await registration.snapshot
        recordRegistrationOutcome(registrationSnapshot)
    }

    /// Make the APNs callback failure visible without retaining Apple's
    /// free-form error text, which can contain unstable device details.
    public func handleDeviceTokenFailure(error: (any Error)? = nil) async {
        diagnosticLog?.recordAppEvent(
            .pushDeviceTokenRegistrationFailed,
            failure: error.map(DiagnosticFailureKind.classify) ?? .unknown
        )
        await registration.deviceTokenRegistrationFailed()
        registrationSnapshot = await registration.snapshot
    }

    /// User-triggered repair for a failed APNs token callback.
    public func retryDeviceTokenRegistration() {
        diagnosticLog?.recordAppEvent(.pushRemoteRegistrationRequested)
        hasRequestedRemoteRegistration = true
        registerForRemoteNotifications()
    }

    /// Re-upload the cached token when possible (e.g. after sign-in).
    public func syncTokenIfPossible() async {
        diagnosticLog?.recordAppEvent(.pushBackendSyncStarted)
        await registration.syncTokenIfPossible()
        registrationSnapshot = await registration.snapshot
        recordRegistrationOutcome(registrationSnapshot)
    }

    /// Refreshes live OS authorization and the current registration stage.
    ///
    /// Call on every foreground transition because users can revoke permission
    /// in iOS Settings while cmux is suspended.
    public func refreshReadiness() async {
        await refreshReadiness(settingsMutationToken: settingsMutationToken)
    }

    private func refreshReadiness(settingsMutationToken: UUID) async {
        let registrationGeneration = self.registrationIntentGeneration
        let settings = await notificationSettings()
        guard isCurrentSettingsMutation(settingsMutationToken) else { return }
        apply(settings: settings)
        if enabledMirror, Self.permitsDelivery(settings.authorization) {
            await activateRegistrationIfNeeded(
                settingsMutationToken: settingsMutationToken,
                registrationGeneration: registrationGeneration
            )
        }
        await recoverRegistrationIfNeeded(
            settingsMutationToken: settingsMutationToken
        )
    }

    private func persistEnabledIntent() {
        enabledMirror = true
        defaults.set(true, forKey: Self.enabledKey)
    }

    private func apply(settings: MobilePushSystemSettings) {
        systemSettings = settings
        authorization = settings.authorization
    }

    private func activateRegistrationIfNeeded(
        settingsMutationToken: UUID,
        registrationGeneration: UInt64
    ) async {
        guard isCurrentSettingsMutation(settingsMutationToken),
              enabledMirror,
              Self.permitsDelivery(authorization)
        else { return }
        let current = await registration.snapshot
        guard isCurrentSettingsMutation(settingsMutationToken), enabledMirror else {
            return
        }
        registrationSnapshot = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: current.hasDeviceToken,
            backendState: current.hasDeviceToken
                ? .registrationRequired
                : .awaitingDeviceToken
        )
        requestRemoteRegistrationIfNeeded()
        // Always submit the current generation. The snapshot can still say
        // enabled while an older disable is queued or suspended; the service
        // intent queue coalesces repeated completed generations without
        // issuing another registration request.
        await registration.applyEnabledIntent(
            true,
            generation: registrationGeneration
        )
        guard isCurrentSettingsMutation(settingsMutationToken), enabledMirror else {
            return
        }
        let snapshot = await registration.snapshot
        guard isCurrentSettingsMutation(settingsMutationToken), enabledMirror else {
            return
        }
        registrationSnapshot = snapshot
    }

    private func requestRemoteRegistrationIfNeeded() {
        guard !hasRequestedRemoteRegistration else { return }
        diagnosticLog?.recordAppEvent(.pushRemoteRegistrationRequested)
        hasRequestedRemoteRegistration = true
        registerForRemoteNotifications()
    }

    private static func permitsDelivery(
        _ authorization: MobilePushAuthorization
    ) -> Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied, .unsupported:
            false
        }
    }

    /// Retries an exhausted registration when a meaningful network path
    /// change reports that the API may be reachable again.
    public func networkDidBecomeReachable() async {
        await recoverRegistrationIfNeeded(
            settingsMutationToken: settingsMutationToken
        )
    }

    private func recoverRegistrationIfNeeded(
        settingsMutationToken: UUID
    ) async {
        guard isCurrentSettingsMutation(settingsMutationToken) else {
            return
        }
        guard enabledMirror else {
            registrationSnapshot = .disabled
            return
        }
        let current = await registration.snapshot
        guard isCurrentSettingsMutation(settingsMutationToken) else {
            return
        }
        guard enabledMirror else {
            registrationSnapshot = .disabled
            return
        }
        registrationSnapshot = current
        guard current.isEnabled, current.hasDeviceToken,
              current.backendState == .registrationRequired
                || current.backendState.isRecoverable
        else { return }

        let recovery: Task<PushRegistrationSnapshot, Never>
        let ownsRecovery: Bool
        let recoveryToken: UUID?
        if let registrationRecoveryTask {
            recovery = registrationRecoveryTask
            ownsRecovery = false
            recoveryToken = nil
        } else {
            let registration = self.registration
            let token = UUID()
            recovery = Task {
                await registration.syncTokenIfPossible()
                return await registration.snapshot
            }
            registrationRecoveryTask = recovery
            registrationRecoveryToken = token
            ownsRecovery = true
            recoveryToken = token
        }
        let recovered = await recovery.value
        // Clear an owned task before checking the caller's generation or
        // cancellation. The recovery worker is independent of the caller's
        // waiter, so a cancelled waiter still must release the cached worker
        // for the next recovery attempt.
        if ownsRecovery, registrationRecoveryToken == recoveryToken {
            registrationRecoveryTask = nil
            registrationRecoveryToken = nil
        }
        guard isCurrentSettingsMutation(settingsMutationToken) else {
            return
        }
        guard enabledMirror else {
            return
        }
        registrationSnapshot = recovered
        recordRegistrationOutcome(recovered)
    }

    private func recordRegistrationOutcome(_ snapshot: PushRegistrationSnapshot) {
        switch snapshot.backendState {
        case .registered:
            diagnosticLog?.recordAppEvent(.pushBackendSyncSucceeded)
        case .deviceTokenRegistrationFailed:
            diagnosticLog?.recordAppEvent(
                .pushBackendSyncFailed,
                failure: .endpointUnavailable
            )
        case .failed(let failure):
            diagnosticLog?.recordAppEvent(
                .pushBackendSyncFailed,
                failure: Self.diagnosticFailure(for: failure)
            )
        case .awaitingDeviceToken, .registrationRequired, .registering:
            break
        }
    }

    private static func diagnosticFailure(
        for failure: PushRegistrationFailure
    ) -> DiagnosticFailureKind {
        switch failure {
        case .authenticationRequired, .accountDeletionInProgress, .rejected:
            .authorizationFailed
        case .rateLimited:
            .policyUnavailable
        case .deviceLimitReached:
            .permissionDenied
        case .networkUnavailable:
            .offline
        case .serviceUnavailable:
            .endpointUnavailable
        case .invalidConfiguration:
            .unsupportedRoute
        case .invalidServerResponse:
            .protocolViolation
        }
    }

    /// Computes readiness against the currently focused Mac's authenticated
    /// status. A missing Mac status fails closed.
    public func readiness(
        macStatus: MobileHostPhonePushStatus?,
        macAccountMismatch: Bool = false
    ) -> MobilePushReadiness {
        MobilePushReadiness.resolve(
            authorization: authorization,
            registration: registrationSnapshot,
            mac: macStatus.map(MobilePushReadiness.MacStatus.init),
            macAccountMismatch: macAccountMismatch,
            systemSettings: systemSettings,
            phoneAPIOrigin: phoneAPIOrigin
        )
    }

    /// Opens this app's iOS notification settings for a denied authorization.
    public func openSystemSettings() {
        guard let url = URL(
            string: UIApplication.openNotificationSettingsURLString
        ) else { return }
        UIApplication.shared.open(url)
    }

    private func startRegistrationSnapshotObservation() {
        registrationSnapshotTask?.cancel()
        registrationSnapshotTask = Task { [weak self, registration] in
            let snapshots = await registration.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { return }
                // A service mutation can finish after a newer toggle has
                // changed the coordinator mirror. Its opposite-state snapshot
                // is stale and must not overwrite the current intent's UI.
                guard snapshot.isEnabled == self.enabledMirror else { continue }
                self.registrationSnapshot = snapshot
            }
        }
    }

    private static func authorization(
        from status: UNAuthorizationStatus
    ) -> MobilePushAuthorization {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .unsupported
        }
    }

    private static func systemSettings(
        from settings: UNNotificationSettings
    ) -> MobilePushSystemSettings {
        MobilePushSystemSettings(
            authorization: authorization(from: settings.authorizationStatus),
            alertsEnabled: settings.alertSetting == .enabled,
            soundsEnabled: settings.soundSetting == .enabled,
            badgesEnabled: settings.badgeSetting == .enabled,
            lockScreenEnabled: settings.lockScreenSetting == .enabled,
            notificationCenterEnabled:
                settings.notificationCenterSetting == .enabled,
            timeSensitiveEnabled: settings.timeSensitiveSetting == .enabled,
            scheduledDeliveryEnabled:
                settings.scheduledDeliverySetting == .enabled
        )
    }

    /// Remove the cached token from the server (on sign-out), authenticating
    /// with the credentials captured before the local-first sign-out cleared
    /// the live token store.
    public func unregisterFromServer(accessToken: String?, refreshToken: String?) async {
        await registration.unregisterFromServer(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Sign-out cleanup pinned to the user id captured before auth clear.
    public func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {
        await registration.unregisterFromServer(
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    deinit {
        settingsMutationTask?.cancel()
        registrationSnapshotTask?.cancel()
        registrationRecoveryTask?.cancel()
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        shouldPresentInForeground(workspaceId: workspaceId, surfaceId: surfaceId, macDeviceId: nil)
    }

    /// Whether to show a banner while the app is foreground, scoped to the Mac
    /// that sent the notification when the payload includes it.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?, macDeviceId: String?) -> Bool {
        diagnosticLog?.recordAppEvent(.pushReceivedInForeground)
        let shouldPresent: Bool
        if let store, let workspaceId,
           store.selectedWorkspaceMatches(remoteWorkspaceID: workspaceId, macDeviceID: macDeviceId) {
            if let surfaceId {
                shouldPresent = store.selectedTerminalID?.rawValue != surfaceId
            } else {
                shouldPresent = false
            }
        } else {
            shouldPresent = true
        }
        diagnosticLog?.recordAppEvent(
            shouldPresent ? .pushPresentedInForeground : .pushSuppressedInForeground
        )
        return shouldPresent
    }

    /// Deep-link to the workspace/terminal a tapped notification refers to.
    ///
    /// The tap is parked first and applied through one path: a cold launch
    /// delivers the tap before the root view has bound a store, and a
    /// warm-but-detached app has not loaded the workspace yet. Navigating
    /// immediately in those states is what stranded users on the workspaces
    /// home screen.
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        handleTap(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: nil,
            retargetsToLiveSurfaceOwner: true
        )
    }

    /// Deep-link to the workspace/terminal a tapped notification refers to,
    /// using the sending Mac id to disambiguate duplicate Mac-local ids.
    /// - Parameters:
    ///   - workspaceId: The Mac-local workspace claim carried by the push.
    ///   - surfaceId: The exact terminal claim carried by the push.
    ///   - macDeviceId: The Mac that owns the claimed ids.
    ///   - retargetsToLiveSurfaceOwner: Whether a moved terminal may resolve in
    ///     a workspace other than the explicit claim. Defaults to `true` for
    ///     pushes from older Mac clients that predate confinement provenance.
    public func handleTap(
        workspaceId: String?,
        surfaceId: String?,
        macDeviceId: String?,
        retargetsToLiveSurfaceOwner: Bool = true
    ) {
        diagnosticLog?.recordAppEvent(.pushTapped)
        pendingDeeplink = PendingDeeplink(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: macDeviceId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            createdAt: now(),
            lastNavigatedWorkspaceId: nil
        )
        diagnosticLog?.recordAppEvent(.pushDeeplinkParked)
        applyPendingDeeplinkIfReady()
    }

    /// Parks an inline notification reply and sends it once its exact Mac, workspace, surface, and RPC channel are ready.
    ///
    /// This path never changes the selected Mac, workspace, terminal, or navigation state.
    /// - Parameters:
    ///   - text: The user's reply text, without the submit Return.
    ///   - workspaceId: The Mac-local workspace claim carried by the push.
    ///   - surfaceId: The exact terminal claim carried by the push.
    ///   - macDeviceId: The Mac that owns the claimed ids.
    ///   - retargetsToLiveSurfaceOwner: Whether a moved terminal may resolve in a
    ///     workspace other than the explicit claim.
    public func handleReply(
        text: String,
        workspaceId: String?,
        surfaceId: String?,
        macDeviceId: String?,
        retargetsToLiveSurfaceOwner: Bool
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        diagnosticLog?.recordAppEvent(.pushReplyStarted)
        pendingReplyState.park(PendingReply(
            text: text,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: macDeviceId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            createdAt: now()
        ))
        await applyPendingReplyIfReady()
    }

    /// Apply the parked tap if its target can be navigated to right now;
    /// otherwise keep it parked for the next ``bind(store:)`` or
    /// ``workspacesDidChange()``.
    private func applyPendingDeeplinkIfReady() {
        guard let pending = pendingDeeplink else { return }
        guard now().timeIntervalSince(pending.createdAt) < Self.pendingDeeplinkLifetime else {
            pendingDeeplink = nil
            diagnosticLog?.recordAppEvent(
                .pushDeeplinkExpired,
                failure: .timedOut
            )
            analytics.capture("ios_push_deeplink_failed", ["reason": .string("expired")])
            return
        }
        guard let store else { return }
        guard pending.retargetsToLiveSurfaceOwner || pending.workspaceId != nil else {
            pendingDeeplink = nil
            diagnosticLog?.recordAppEvent(
                .pushDeeplinkFailed,
                failure: .protocolViolation
            )
            return
        }

        // Resolve the workspace to navigate to: the explicit target, or for a
        // surface-only tap the workspace that owns the terminal. Unresolvable
        // means "not loaded yet": stay parked for the next topology change so
        // the tap is never spent on a selection that cannot navigate.
        var workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            guard let resolved = store.workspaceID(
                matchingRemoteWorkspaceID: workspaceId,
                macDeviceID: pending.macDeviceId
            ) else { return }
            workspaceTarget = resolved
        } else if let surfaceId = pending.surfaceId {
            guard let owner = store.workspaceID(
                containingSurfaceID: surfaceId,
                macDeviceID: pending.macDeviceId
            ) else { return }
            workspaceTarget = owner
        } else {
            pendingDeeplink = nil
            diagnosticLog?.recordAppEvent(
                .pushDeeplinkFailed,
                failure: .protocolViolation
            )
            return
        }
        if pending.retargetsToLiveSurfaceOwner,
           let surfaceId = pending.surfaceId,
           let liveOwner = store.workspaceID(
               containingSurfaceID: surfaceId,
               macDeviceID: pending.macDeviceId
           ) {
            workspaceTarget = liveOwner
        }

        if let surfaceId = pending.surfaceId,
           !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            // The workspace is here but its terminal snapshot is not (still
            // loading, closed, or moved). Land the user in the right workspace.
            if pending.lastNavigatedWorkspaceId != workspaceTarget {
                store.navigateToWorkspaceForDeeplink(workspaceTarget)
            }
            if !pending.retargetsToLiveSurfaceOwner,
               let liveOwner = store.workspaceID(
                   containingSurfaceID: surfaceId,
                   macDeviceID: pending.macDeviceId
               ),
               liveOwner != workspaceTarget {
                // The loaded topology proves the terminal moved elsewhere. A
                // confined tap cannot follow it, and retaining the request
                // would replay navigation to the authorized workspace on every
                // topology update.
                pendingDeeplink = nil
                diagnosticLog?.recordAppEvent(.pushDeeplinkResolved)
                analytics.capture("ios_push_deeplink_resolved", [
                    "resolved_workspace": .bool(true),
                    "resolved_surface": .bool(false),
                ])
                return
            }
            // No live owner is loaded yet. Keep the surface parked so a pending
            // snapshot can still arrive, bounded by the original expiry.
            pendingDeeplink = PendingDeeplink(
                workspaceId: pending.retargetsToLiveSurfaceOwner ? nil : pending.workspaceId,
                surfaceId: surfaceId,
                macDeviceId: pending.macDeviceId,
                retargetsToLiveSurfaceOwner: pending.retargetsToLiveSurfaceOwner,
                createdAt: pending.createdAt,
                lastNavigatedWorkspaceId: workspaceTarget
            )
            return
        }

        if pending.lastNavigatedWorkspaceId != workspaceTarget {
            store.navigateToWorkspaceForDeeplink(workspaceTarget)
        }
        if let surfaceId = pending.surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
        pendingDeeplink = nil
        diagnosticLog?.recordAppEvent(.pushDeeplinkResolved)
        analytics.capture("ios_push_deeplink_resolved", [
            "resolved_workspace": .bool(pending.workspaceId != nil),
            "resolved_surface": .bool(pending.surfaceId != nil),
        ])
    }

    /// Applies the parked reply without mutating UI selection; later topology changes retry only unresolved prerequisites.
    private func applyPendingReplyIfReady() async {
        guard !replySendInFlight else { return }
        let initialDecision = pendingReplyState.evaluate(
            now: now(),
            isStoreBound: store != nil,
            isTargetReachable: false,
            isChannelAvailable: false
        )
        switch initialDecision {
        case .noPending:
            return
        case .expired:
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .timedOut
            )
            mobilePushLog.info("dropping expired inline reply")
            return
        case .waiting:
            break
        case .ready:
            return
        }

        guard let pending = pendingReplyState.pending, let store else { return }
        guard let surfaceId = pending.surfaceId, !surfaceId.isEmpty else {
            pendingReplyState.discard()
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .protocolViolation
            )
            mobilePushLog.info("dropping inline reply without a surface id")
            return
        }

        var workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            guard let resolved = store.workspaceID(
                matchingRemoteWorkspaceID: workspaceId,
                macDeviceID: pending.macDeviceId
            ) else { return }
            workspaceTarget = resolved
        } else if pending.retargetsToLiveSurfaceOwner {
            guard let owner = store.workspaceID(
                containingSurfaceID: surfaceId,
                macDeviceID: pending.macDeviceId
            ) else { return }
            workspaceTarget = owner
        } else {
            pendingReplyState.discard()
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .protocolViolation
            )
            mobilePushLog.info("dropping confined inline reply without a workspace id")
            return
        }

        if !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            guard pending.retargetsToLiveSurfaceOwner,
                  let liveOwner = store.workspaceID(
                      containingSurfaceID: surfaceId,
                      macDeviceID: pending.macDeviceId
              ) else {
                pendingReplyState.discard()
                diagnosticLog?.recordAppEvent(
                    .pushReplyFailed,
                    failure: .noRoute
                )
                mobilePushLog.info("dropping inline reply because the target surface has no permitted live owner")
                return
            }
            workspaceTarget = liveOwner
        }

        let decision = pendingReplyState.evaluate(
            now: now(),
            isStoreBound: true,
            isTargetReachable: true,
            isChannelAvailable: store.canSendTerminalInput(to: workspaceTarget)
        )
        guard case .ready(let ready) = decision else {
            if case .expired = decision {
                mobilePushLog.info("dropping expired inline reply")
                return
            }
            // Channel not ready. A store/channel event retries immediately,
            // but a channel that recovers without one would otherwise strand
            // the reply until its lifetime expires — keep the bounded retry
            // ladder armed while parked.
            scheduleReplyRetry()
            return
        }

        replySendInFlight = true
        let sent = await store.sendTerminalInput(
            ready.text + "\r",
            workspaceID: workspaceTarget,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceId)
        )
        replySendInFlight = false
        if !sent {
            // A failed RPC send must not consume the reply: re-park it (with
            // its original createdAt, so the 120 s lifetime still bounds the
            // total retry window). A reply parked mid-send wins instead —
            // latest user intent replaces the failed one. Store/channel
            // readiness events retry immediately; the armed delay covers a
            // transient failure whose topology never changes.
            mobilePushLog.error("inline reply terminal input failed; re-parking for retry")
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .connectionClosed
            )
            if pendingReplyState.pending == nil {
                pendingReplyState.park(ready)
            }
            scheduleReplyRetry()
            return
        }
        replyRetryTask?.cancel()
        replyRetryTask = nil
        diagnosticLog?.recordAppEvent(.pushReplySucceeded)
        await applyPendingReplyIfReady()
    }

    /// Arms one delayed `applyPendingReplyIfReady` pass (see `replyRetryTask`).
    private func scheduleReplyRetry() {
        replyRetryTask?.cancel()
        replyRetryTask = Task { @MainActor [weak self, replyRetrySleep] in
            guard (try? await replyRetrySleep(Self.replyRetryDelay)) != nil else { return }
            guard let self, !Task.isCancelled else { return }
            self.replyRetryTask = nil
            await self.applyPendingReplyIfReady()
        }
    }

    /// Forward a phone-side notification dismissal to the paired Mac so it marks
    /// the notification read and clears its own banner. Fire-and-forget over the
    /// attach channel; carries only the opaque notification id, never content.
    ///
    /// Durable: a swipe can background-launch the app from Notification Center
    /// before any scene — and therefore any store — exists. In that case the id
    /// is parked in ``PendingNotificationDismissQueue`` and the store flushes it
    /// on its next successful (re)subscribe. With a store, the store's own
    /// enqueue-first send provides the same guarantee for a down channel.
    /// - Parameters:
    ///   - notificationId: The stable id of the dismissed notification. For a
    ///     remote push this is `request.identifier` (the `apns-collapse-id`),
    ///     with `cmux.notificationId` as a fallback.
    ///   - macDeviceId: The Mac that owns the notification, from the `cmux`
    ///     payload. Missing older payloads route through the foreground Mac.
    public func handleDismiss(notificationId: String?, macDeviceId: String?) async {
        guard let notificationId else {
            diagnosticLog?.recordAppEvent(.pushDismissFailed, failure: .protocolViolation)
            return
        }
        let trimmed = notificationId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            diagnosticLog?.recordAppEvent(.pushDismissFailed, failure: .protocolViolation)
            return
        }
        diagnosticLog?.recordAppEvent(.pushDismissStarted)
        let mac = macDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store else {
            pendingDismissQueue.enqueue([trimmed], macDeviceID: mac?.isEmpty == false ? mac : nil)
            diagnosticLog?.recordAppEvent(.pushDismissSucceeded)
            return
        }
        await store.dismissNotification(ids: [trimmed], macDeviceID: mac?.isEmpty == false ? mac : nil)
        diagnosticLog?.recordAppEvent(.pushDismissSucceeded)
    }

    /// Handle a silent Mac→iOS dismiss push (the cold lane, fanned out to every
    /// registered device after a Mac-side clear). Removes the matching
    /// delivered banners directly through the system-notification seam — the
    /// store may not exist yet on a background wake — while the badge was
    /// already applied by the system from the push's `aps.badge`.
    /// - Parameter ids: The dismissed stable notification ids from
    ///   `cmux.dismissedIds`.
    public func handleRemoteDismiss(ids: [String]) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        diagnosticLog?.recordAppEvent(
            .pushRemoteDismissReceived,
            count: trimmed.count
        )
        await deliveredNotificationClearer.removeDelivered(ids: trimmed)
        diagnosticLog?.recordAppEvent(.pushRemoteDismissApplied, count: trimmed.count)
    }

#if DEBUG
    /// Schedules a LOCAL notification carrying the same reply category and
    /// `cmux` userInfo schema as a Mac-forwarded APNs push, addressed at the
    /// currently selected workspace/terminal. The notification-center response
    /// path cannot tell local from remote, so the inline-reply UX and its full
    /// handling chain (action routing, reply parking, `terminal.input` RPC back
    /// to the Mac) are verifiable on a device without any APNs transport — dev
    /// web deployments have no push service configured. Fires after a short
    /// delay so the tester can lock the phone or background the app first.
    /// In this same file so it reaches the private `store` without widening
    /// production visibility for a debug affordance.
    public func debugScheduleLocalReplyNotification() async -> Bool {
        guard let store,
              let workspace = store.selectedWorkspace,
              let surfaceId = store.selectedTerminalID?.rawValue else {
            mobilePushLog.info("debug local reply skipped: no selected workspace/terminal")
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "mobile.push.debugReply.title",
            defaultValue: "cmux reply test",
            bundle: .module
        )
        content.subtitle = workspace.name
        content.body = String(
            localized: "mobile.push.debugReply.body",
            defaultValue: "Reply here; the text is typed into the selected Mac terminal.",
            bundle: .module
        )
        content.categoryIdentifier = Self.replyCategoryIdentifier
        var cmux: [String: Any] = [
            "workspaceId": workspace.rpcWorkspaceID.rawValue,
            "surfaceId": surfaceId,
            "retargetsToLiveSurfaceOwner": true,
        ]
        if let macDeviceId = workspace.macDeviceID, !macDeviceId.isEmpty {
            cmux["macDeviceId"] = macDeviceId
        }
        content.userInfo = ["cmux": cmux]
        let request = UNNotificationRequest(
            identifier: "cmux.debug.reply.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            mobilePushLog.error("debug local reply schedule failed: \(error.localizedDescription)")
            return false
        }
    }
#endif
}
#endif
