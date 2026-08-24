#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobilePairedMac
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

private actor MobilePushSingleFlight<Value: Sendable> {
    private var result: Value?
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    func finish(_ value: Value) {
        guard result == nil else { return }
        result = value
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func wait() async -> Value? {
        if let result { return result }
        if Task.isCancelled { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

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
    @ObservationIgnored private var settingsIntentGeneration: UInt64 = 0
    @ObservationIgnored private var settingsIntentTask: Task<Bool, Never>?

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
        let macInstanceTag: String?
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
    private static let replyRetryDelay: Duration = .seconds(5)
    /// Held from the moment a reply parks until no reply is pending, so a
    /// lock-screen reply's background wake survives past the notification
    /// delegate's return long enough for the relay POST (and its bounded
    /// retries) to complete. Without it iOS suspends the process within
    /// seconds and the parked reply silently expires.
    @ObservationIgnored private var replyBackgroundAssertion: BackgroundReplyRuntimeAssertion?
    @ObservationIgnored private let backgroundRuntime: any BackgroundReplyRuntimeAsserting
    /// Server relay for replies the phone cannot deliver directly: the
    /// reliable lane for a backgrounded app, whose whole job is one HTTPS
    /// POST. The Mac fetches and types the reply on its own schedule.
    @ObservationIgnored private let replyRelay: any ReplyRelaying
    @ObservationIgnored private let replyFailureNotifier: any ReplyFailureNoticing
    /// Grace past ``PendingReplyState/lifetime`` so an in-flight final send
    /// isn't raced by its own failure notice.
    private static let replyFailureNoticeSlack: TimeInterval = 10
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
    @ObservationIgnored private let notificationSettingsClock:
        any Clock<Duration>
    @ObservationIgnored private let notificationSettingsTimeout: Duration
    @ObservationIgnored private var notificationSettingsReadTask:
        Task<Void, Never>?
    @ObservationIgnored private var notificationSettingsOperation:
        MobilePushSingleFlight<MobilePushSystemSettings>?
    @ObservationIgnored private var notificationSettingsReadID: UUID?
    @ObservationIgnored private let requestAuthorization:
        @MainActor () async -> Bool
    @ObservationIgnored private let authorizationRequestTimeout: Duration
    @ObservationIgnored private var authorizationRequestTask: Task<Void, Never>?
    @ObservationIgnored private var authorizationRequestOperation:
        MobilePushSingleFlight<Bool>?
    @ObservationIgnored private var authorizationRequestID: UUID?
    @ObservationIgnored private let registerForRemoteNotifications:
        @MainActor () -> Void
    @ObservationIgnored private let unregisterForRemoteNotifications:
        @MainActor () -> Void
    @ObservationIgnored private var registrationSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var registrationRecoveryTask:
        Task<PushRegistrationSnapshot, Never>?
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
        backgroundRuntime: any BackgroundReplyRuntimeAsserting = SystemBackgroundReplyRuntime(),
        replyRelay: any ReplyRelaying = NoopReplyRelay(),
        replyFailureNotifier: any ReplyFailureNoticing = SystemReplyFailureNotifier(),
        notificationSettingsClock: any Clock<Duration> = ContinuousClock(),
        notificationSettingsTimeout: Duration = .seconds(5),
        authorizationRequestTimeout: Duration = .seconds(120)
    ) {
        self.registration = registration
        self.replyRetrySleep = replyRetrySleep
        self.backgroundRuntime = backgroundRuntime
        self.replyRelay = replyRelay
        self.replyFailureNotifier = replyFailureNotifier
        self.notificationSettingsClock = notificationSettingsClock
        self.notificationSettingsTimeout = notificationSettingsTimeout
        self.authorizationRequestTimeout = authorizationRequestTimeout
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

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { enabledMirror }

    /// Commits a Settings toggle choice synchronously, then reconciles OS and
    /// backend state for that generation. A later choice invalidates every
    /// continuation of the older operation, so Settings never waits behind a
    /// stalled permission or registration call.
    @discardableResult
    public func setEnabledIntent(_ enabled: Bool) -> Task<Bool, Never> {
        settingsIntentTask?.cancel()
        let generation = beginSettingsIntent(enabled)
        let registration = registration
        let task = Task { @MainActor [weak self, registration] in
            await registration.applyEnabledIntent(
                enabled,
                generation: generation
            )
            guard let self else { return false }
            guard !Task.isCancelled,
                  self.isCurrentSettingsIntent(
                      generation,
                      enabled: enabled
                  ) else { return false }
            let result: Bool
            if enabled {
                result = await self.reconcileEnable(
                    trigger: "settings_toggle",
                    generation: generation,
                    registrationIntentOwnedByService: true
                )
                if result,
                   self.isCurrentSettingsIntent(
                       generation,
                       enabled: true
                   ) {
                    await self.registration.reconcileEnabledIntent(
                        generation: generation
                    )
                }
            } else {
                result = true
            }
            if self.settingsIntentGeneration == generation {
                self.settingsIntentTask = nil
            }
            return result
        }
        settingsIntentTask = task
        return task
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
        await setEnabledIntent(true).value
    }

    /// Requests or recovers push only after the authenticated workspace shell
    /// is mounted. An explicit app opt-out remains authoritative.
    public func workspaceListDidBecomeVisible() async {
        let initialSettingsGeneration = settingsIntentGeneration
        if defaults.object(forKey: Self.enabledKey) as? Bool == false {
            return
        }
        guard let settings = await readNotificationSettingsBounded() else {
            return
        }
        guard settingsIntentGeneration == initialSettingsGeneration,
              defaults.object(forKey: Self.enabledKey) as? Bool != false
        else { return }
        apply(settings: settings)
        switch settings.authorization {
        case .authorized, .provisional, .ephemeral:
            persistEnabledIntent()
            await activateRegistrationIfNeeded()
            await recoverRegistrationIfNeeded()
        case .denied:
            // Preserve intent so Settings can explain the blocked OS gate and
            // a later foreground return can recover without another app launch.
            persistEnabledIntent()
        case .notDetermined:
            guard !workspaceAuthorizationRequestInFlight else { return }
            workspaceAuthorizationRequestInFlight = true
            defer { workspaceAuthorizationRequestInFlight = false }
            let generation = beginSettingsIntent(true)
            _ = await reconcileEnable(
                trigger: "workspace_list",
                generation: generation
            )
        case .unsupported:
            break
        }
    }

    private func reconcileEnable(
        trigger: String,
        generation: UInt64,
        registrationIntentOwnedByService: Bool = false
    ) async -> Bool {
        // Read the OS state immediately before reconciling. The cached value
        // can be stale when the user changes notification permission in iOS
        // Settings while the app is suspended or a readiness refresh is still
        // in flight.
        guard let priorSettings = await readNotificationSettingsBounded() else {
            return false
        }
        guard isCurrentSettingsIntent(generation, enabled: true) else {
            return false
        }
        apply(settings: priorSettings)
        let priorStatus = priorSettings.authorization
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
            granted = await requestAuthorizationBounded() ?? false
        case .denied, .unsupported:
            granted = false
        }
        guard isCurrentSettingsIntent(generation, enabled: true) else {
            return false
        }
        guard granted else {
            await refreshReadiness()
            guard isCurrentSettingsIntent(generation, enabled: true) else {
                return false
            }
            diagnosticLog?.recordAppEvent(.pushAuthorizationDenied)
            analytics.capture("ios_push_optin_declined", [
                "trigger": .string(trigger),
                "was_os_level_predenied": .bool(priorStatus == .denied),
            ])
            return false
        }
        if priorStatus == .notDetermined {
            guard let currentSettings = await readNotificationSettingsBounded()
            else { return false }
            guard isCurrentSettingsIntent(generation, enabled: true) else {
                return false
            }
            apply(settings: currentSettings)
        }
        diagnosticLog?.recordAppEvent(.pushAuthorizationGranted)
        analytics.capture("ios_push_optin_granted", ["trigger": .string(trigger)])
        await activateRegistrationIfNeeded(
            settingsGeneration: generation,
            reconcilePreference: !registrationIntentOwnedByService
        )
        guard isCurrentSettingsIntent(generation, enabled: true) else {
            return false
        }
        if registrationIntentOwnedByService {
            return true
        }
        await recoverRegistrationIfNeeded(settingsGeneration: generation)
        guard isCurrentSettingsIntent(generation, enabled: true) else {
            return false
        }
        return true
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        _ = await setEnabledIntent(false).value
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        diagnosticLog?.recordAppEvent(.pushDeviceTokenReceived, count: token.count)
        diagnosticLog?.recordAppEvent(.pushBackendSyncStarted)
        await registration.register(deviceToken: token)
        let snapshot = await registration.snapshot
        guard snapshot.isEnabled == enabledMirror else { return }
        registrationSnapshot = snapshot
        recordRegistrationOutcome(snapshot)
    }

    /// Make the APNs callback failure visible without retaining Apple's
    /// free-form error text, which can contain unstable device details.
    public func handleDeviceTokenFailure(error: (any Error)? = nil) async {
        diagnosticLog?.recordAppEvent(
            .pushDeviceTokenRegistrationFailed,
            failure: error.map(DiagnosticFailureKind.classify) ?? .unknown
        )
        await registration.deviceTokenRegistrationFailed()
        let snapshot = await registration.snapshot
        guard snapshot.isEnabled == enabledMirror else { return }
        registrationSnapshot = snapshot
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
        let snapshot = await registration.snapshot
        guard snapshot.isEnabled == enabledMirror else { return }
        registrationSnapshot = snapshot
        recordRegistrationOutcome(snapshot)
    }

    /// Refreshes live OS authorization and the current registration stage.
    ///
    /// Call on every foreground transition because users can revoke permission
    /// in iOS Settings while cmux is suspended.
    public func refreshReadiness() async {
        guard let settings = await readNotificationSettingsBounded() else {
            return
        }
        apply(settings: settings)
        if enabledMirror, Self.permitsDelivery(settings.authorization) {
            await activateRegistrationIfNeeded()
        }
        await recoverRegistrationIfNeeded()
    }

    private func persistEnabledIntent() {
        enabledMirror = true
        defaults.set(true, forKey: Self.enabledKey)
    }

    private func beginSettingsIntent(_ enabled: Bool) -> UInt64 {
        settingsIntentGeneration &+= 1
        // Commit the synchronous source of truth before any actor hop. The
        // Settings binding reads this value again in the same render pass.
        enabledMirror = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            diagnosticLog?.recordAppEvent(.pushDisabled)
            registrationSnapshot = .disabled
            hasRequestedRemoteRegistration = false
            unregisterForRemoteNotifications()
        }
        return settingsIntentGeneration
    }

    private func isCurrentSettingsIntent(
        _ generation: UInt64,
        enabled: Bool
    ) -> Bool {
        settingsIntentGeneration == generation && enabledMirror == enabled
    }

    private func apply(settings: MobilePushSystemSettings) {
        systemSettings = settings
        authorization = settings.authorization
    }

    private func readNotificationSettingsBounded() async
        -> MobilePushSystemSettings? {
        // One shared read prevents repeated toggles or foreground callbacks
        // from accumulating cancellation-ignoring UserNotifications tasks.
        if let notificationSettingsOperation {
            return await waitForOperationValue(
                notificationSettingsOperation,
                timeout: notificationSettingsTimeout,
                operationName: "notification settings"
            )
        }
        let id = UUID()
        let reader = notificationSettings
        let operation = MobilePushSingleFlight<MobilePushSystemSettings>()
        let task = Task { @MainActor [weak self, reader, operation] in
            let settings = await reader()
            await operation.finish(settings)
            if let self, self.notificationSettingsReadID == id {
                self.notificationSettingsReadTask = nil
                self.notificationSettingsReadID = nil
                self.notificationSettingsOperation = nil
            }
        }
        notificationSettingsReadID = id
        notificationSettingsReadTask = task
        notificationSettingsOperation = operation
        return await waitForOperationValue(
            operation,
            timeout: notificationSettingsTimeout,
            operationName: "notification settings"
        )
    }

    private func requestAuthorizationBounded() async -> Bool? {
        if let authorizationRequestOperation {
            return await waitForOperationValue(
                authorizationRequestOperation,
                timeout: authorizationRequestTimeout,
                operationName: "notification authorization"
            )
        }
        let id = UUID()
        let requester = requestAuthorization
        let operation = MobilePushSingleFlight<Bool>()
        let task = Task { @MainActor [weak self, requester, operation] in
            let granted = await requester()
            await operation.finish(granted)
            if let self, self.authorizationRequestID == id {
                self.authorizationRequestTask = nil
                self.authorizationRequestID = nil
                self.authorizationRequestOperation = nil
            }
        }
        authorizationRequestID = id
        authorizationRequestTask = task
        authorizationRequestOperation = operation
        return await waitForOperationValue(
            operation,
            timeout: authorizationRequestTimeout,
            operationName: "notification authorization"
        )
    }

    private func waitForOperationValue<Value: Sendable>(
        _ operation: MobilePushSingleFlight<Value>,
        timeout: Duration,
        operationName: String
    ) async -> Value? {
        let clock = notificationSettingsClock
        let result = await withTaskGroup(
            of: Value?.self,
            returning: Value?.self
        ) { group in
            group.addTask {
                await operation.wait()
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if result == nil, !Task.isCancelled {
            mobilePushLog.error("Timed out reading \(operationName, privacy: .public)")
        }
        return result
    }

    private func activateRegistrationIfNeeded(
        settingsGeneration: UInt64? = nil,
        reconcilePreference: Bool = true
    ) async {
        guard enabledMirror, Self.permitsDelivery(authorization) else { return }
        let current = await registration.snapshot
        guard enabledMirror,
              settingsGeneration.map({
                  isCurrentSettingsIntent($0, enabled: true)
              }) ?? true
        else { return }

        let backendState: PushRegistrationBackendState
        if !current.hasDeviceToken {
            backendState = .awaitingDeviceToken
        } else if case .awaitingDeviceToken = current.backendState {
            // A token without an acknowledgement is the only inconsistent
            // snapshot that needs promotion on activation. Preserve every
            // terminal or in-flight state, especially `.registered`, so a
            // warm foreground does not manufacture another POST.
            backendState = .registrationRequired
        } else {
             backendState = current.backendState
         }
        registrationSnapshot = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: current.hasDeviceToken,
            backendState: backendState
        )
        requestRemoteRegistrationIfNeeded()
        if reconcilePreference {
            if current.isEnabled {
                // A prior enable can remain intentionally unreconciled while
                // iOS permission is denied. Foregrounding after permission is
                // granted must release that exact coordinator generation.
                await registration.reconcileEnabledIntent(
                    generation: settingsIntentGeneration
                )
            } else {
                await registration.setEnabled(true)
            }
        }
        guard enabledMirror,
              settingsGeneration.map({
                  isCurrentSettingsIntent($0, enabled: true)
              }) ?? true
        else { return }
        let snapshot = await registration.snapshot
        guard enabledMirror,
              settingsGeneration.map({
                  isCurrentSettingsIntent($0, enabled: true)
              }) ?? true
        else { return }
        if snapshot.isEnabled == enabledMirror {
            registrationSnapshot = snapshot
        }
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
        await recoverRegistrationIfNeeded()
    }

    private func recoverRegistrationIfNeeded(
        settingsGeneration: UInt64? = nil
    ) async {
        let current = await registration.snapshot
        guard settingsGeneration.map({
            isCurrentSettingsIntent($0, enabled: true)
        }) ?? true else { return }
        guard current.isEnabled == enabledMirror else { return }
        registrationSnapshot = current
        guard current.isEnabled, current.hasDeviceToken,
              current.backendState == .registrationRequired
                || current.backendState.isRecoverable
        else { return }

        let recovery: Task<PushRegistrationSnapshot, Never>
        let ownsRecovery: Bool
        if let registrationRecoveryTask {
            recovery = registrationRecoveryTask
            ownsRecovery = false
        } else {
            let registration = self.registration
            recovery = Task {
                await registration.syncTokenIfPossible()
                return await registration.snapshot
            }
            registrationRecoveryTask = recovery
            ownsRecovery = true
        }
        let recovered = await recovery.value
        if ownsRecovery {
            registrationRecoveryTask = nil
        }
        guard settingsGeneration.map({
            isCurrentSettingsIntent($0, enabled: true)
        }) ?? true else { return }
        guard recovered.isEnabled == enabledMirror else { return }
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

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        shouldPresentInForeground(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: nil,
            macInstanceTag: nil
        )
    }

    /// Whether to show a banner while the app is foreground, scoped to the Mac
    /// that sent the notification when the payload includes it.
    public func shouldPresentInForeground(
        workspaceId: String?,
        surfaceId: String?,
        macDeviceId: String?,
        macInstanceTag: String? = nil
    ) -> Bool {
        diagnosticLog?.recordAppEvent(.pushReceivedInForeground)
        let shouldPresent: Bool
        if let store, let workspaceId,
           store.selectedWorkspaceMatches(
               remoteWorkspaceID: workspaceId,
               macDeviceID: macDeviceId,
               instanceTag: macInstanceTag
           ) {
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
            macInstanceTag: nil,
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
        macInstanceTag: String? = nil,
        retargetsToLiveSurfaceOwner: Bool = true
    ) {
        diagnosticLog?.recordAppEvent(.pushTapped)
        pendingDeeplink = PendingDeeplink(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: macDeviceId,
            macInstanceTag: macInstanceTag,
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
        macInstanceTag: String? = nil,
        retargetsToLiveSurfaceOwner: Bool
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        diagnosticLog?.recordAppEvent(.pushReplyStarted)
        let supersededReplyId = pendingReplyState.pending?.replyId
        let replyId = UUID().uuidString
        pendingReplyState.park(PendingReply(
            replyId: replyId,
            text: text,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            macDeviceId: macDeviceId,
            macInstanceTag: macInstanceTag,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            createdAt: now()
        ))
        // A lock-screen reply wakes the app in the BACKGROUND: hold runtime so
        // the relay POST + retry ladder outlive the notification delegate, and
        // pre-schedule the failure notice so even a process kill cannot turn a
        // lost reply into silence. Both resolve when the reply does. Notices
        // are keyed per reply id, so a superseded reply's notice is cancelled
        // here and an older reply resolving can never void a newer notice.
        beginReplyBackgroundAssertionIfNeeded()
        await replyFailureNotifier.schedule(
            after: PendingReplyState.lifetime + Self.replyFailureNoticeSlack,
            replyId: replyId
        )
        if let supersededReplyId {
            await replyFailureNotifier.cancel(replyId: supersededReplyId)
        }
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
                macDeviceID: pending.macDeviceId,
                instanceTag: pending.macInstanceTag
            ) else { return }
            workspaceTarget = resolved
        } else if let surfaceId = pending.surfaceId {
            guard let owner = store.workspaceID(
                containingSurfaceID: surfaceId,
                macDeviceID: pending.macDeviceId,
                instanceTag: pending.macInstanceTag
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
               macDeviceID: pending.macDeviceId,
               instanceTag: pending.macInstanceTag
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
                   macDeviceID: pending.macDeviceId,
                   instanceTag: pending.macInstanceTag
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
                macInstanceTag: pending.macInstanceTag,
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
    /// Also reconciles the reply background assertion: it is held exactly while
    /// a reply is pending (or a send is in flight), so every resolution path —
    /// sent, relayed, discarded, expired — releases the process back to iOS.
    private func applyPendingReplyIfReady() async {
        await applyPendingReplyIfReadyCore()
        if pendingReplyState.pending == nil, !replySendInFlight {
            endReplyBackgroundAssertionIfHeld()
        }
    }

    private func applyPendingReplyIfReadyCore() async {
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

        guard let pending = pendingReplyState.pending else { return }
        guard let surfaceId = pending.surfaceId, !surfaceId.isEmpty else {
            pendingReplyState.discard()
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .protocolViolation
            )
            mobilePushLog.info("dropping inline reply without a surface id")
            await replyFailureNotifier.deliverNow(replyId: pending.replyId)
            return
        }

        // A backgrounded app is never asked to dial: the direct RPC lane is a
        // fast path taken only when it can deliver RIGHT NOW. Everything else
        // — no store yet (a store-less background wake), a target the local
        // topology cannot resolve, a down or freshly-dead channel — hands the
        // reply to the server relay in one HTTPS POST and lets the Mac fetch
        // and type it.
        guard let store else {
            await relayPendingReply(pending)
            return
        }

        var workspaceTarget: MobileWorkspacePreview.ID
        if let workspaceId = pending.workspaceId {
            guard let resolved = store.workspaceID(
                matchingRemoteWorkspaceID: workspaceId,
                macDeviceID: pending.macDeviceId,
                instanceTag: pending.macInstanceTag
            ) else {
                await relayPendingReply(pending)
                return
            }
            workspaceTarget = resolved
        } else if pending.retargetsToLiveSurfaceOwner {
            guard let owner = store.workspaceID(
                containingSurfaceID: surfaceId,
                macDeviceID: pending.macDeviceId,
                instanceTag: pending.macInstanceTag
            ) else {
                await relayPendingReply(pending)
                return
            }
            workspaceTarget = owner
        } else {
            pendingReplyState.discard()
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .protocolViolation
            )
            mobilePushLog.info("dropping confined inline reply without a workspace id")
            await replyFailureNotifier.deliverNow(replyId: pending.replyId)
            return
        }

        if !store.workspace(workspaceTarget, containsSurfaceID: surfaceId) {
            guard pending.retargetsToLiveSurfaceOwner,
                  let liveOwner = store.workspaceID(
                      containingSurfaceID: surfaceId,
                      macDeviceID: pending.macDeviceId,
                      instanceTag: pending.macInstanceTag
              ) else {
                // The LOCAL topology says the target is gone, but a suspended
                // snapshot is not authoritative — the Mac's resolution is.
                // Relay and let the shared terminal.input path decide there.
                await relayPendingReply(pending)
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
            // Channel not usable right now; the relay does not wait for it.
            await relayPendingReply(pending)
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
            // its original createdAt, so the lifetime still bounds the total
            // retry window; a reply parked mid-send wins instead), then hand
            // it straight to the relay — the channel just proved unreliable.
            mobilePushLog.error("inline reply terminal input failed; relaying")
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .connectionClosed
            )
            if pendingReplyState.pending == nil {
                pendingReplyState.park(ready)
            }
            await relayPendingReply(ready)
            return
        }
        replyRetryTask?.cancel()
        replyRetryTask = nil
        diagnosticLog?.recordAppEvent(.pushReplySucceeded)
        // Per-reply notices: cancelling this reply's notice can never void a
        // newer reply's.
        await replyFailureNotifier.cancel(replyId: ready.replyId)
        await applyPendingReplyIfReady()
    }

    /// The reliable lane: park the reply in the presence worker's inbox with
    /// one HTTPS POST; the Mac fetches and types it through the same shared
    /// terminal.input path as a direct send. Consumes the reply on acceptance.
    /// A reply whose push carried no Mac claim cannot be routed by the inbox
    /// (and a Mac old enough to omit the claim cannot sweep it either), so it
    /// stays parked for a late direct send within its lifetime.
    private func relayPendingReply(_ pending: PendingReply) async {
        guard let surfaceId = pending.surfaceId, !surfaceId.isEmpty else { return }
        guard let macDeviceId = pending.macDeviceId, !macDeviceId.isEmpty else {
            scheduleReplyRetry()
            return
        }
        guard !replySendInFlight else { return }
        replySendInFlight = true
        let accepted = await replyRelay.relay(RelayedReply(
            replyId: pending.replyId,
            macDeviceId: macDeviceId,
            workspaceId: pending.workspaceId,
            surfaceId: surfaceId,
            text: pending.text
        ))
        replySendInFlight = false
        guard accepted else {
            // Transient service failure: stay parked. The ladder re-runs the
            // whole decision — direct first, relay again — within the
            // reply's lifetime, and the pre-scheduled notice reports a reply
            // that never leaves the phone.
            mobilePushLog.error("inline reply relay POST failed; retrying on the ladder")
            diagnosticLog?.recordAppEvent(
                .pushReplyFailed,
                failure: .connectionClosed
            )
            scheduleReplyRetry()
            return
        }
        pendingReplyState.discardIfMatching(replyId: pending.replyId)
        replyRetryTask?.cancel()
        replyRetryTask = nil
        diagnosticLog?.recordAppEvent(.pushReplySucceeded)
        mobilePushLog.info("inline reply parked in the server relay inbox")
        // Per-reply notices: cancelling this reply's notice can never void a
        // newer reply's.
        await replyFailureNotifier.cancel(replyId: pending.replyId)
        await applyPendingReplyIfReady()
    }

    private func beginReplyBackgroundAssertionIfNeeded() {
        guard replyBackgroundAssertion == nil else { return }
        replyBackgroundAssertion = backgroundRuntime.begin { [weak self] in
            // The system window is closing; release promptly. The reply stays
            // parked — a foreground within its lifetime still delivers it, and
            // the pre-scheduled failure notice reports it otherwise.
            self?.endReplyBackgroundAssertionIfHeld()
        }
    }

    private func endReplyBackgroundAssertionIfHeld() {
        guard let assertion = replyBackgroundAssertion else { return }
        replyBackgroundAssertion = nil
        backgroundRuntime.end(assertion)
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
    public func handleDismiss(
        notificationId: String?,
        macDeviceId: String?,
        macInstanceTag: String? = nil
    ) async {
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
        let tag = macInstanceTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store else {
            pendingDismissQueue.enqueue(
                [trimmed],
                macDeviceID: mac?.isEmpty == false ? mac : nil,
                instanceTag: tag?.isEmpty == false ? tag : nil
            )
            diagnosticLog?.recordAppEvent(.pushDismissSucceeded)
            return
        }
        await store.dismissNotification(
            ids: [trimmed],
            macDeviceID: mac?.isEmpty == false ? mac : nil,
            instanceTag: tag?.isEmpty == false ? tag : nil
        )
        diagnosticLog?.recordAppEvent(.pushDismissSucceeded)
    }

    /// Handle a silent Mac→iOS dismiss push (the cold lane, fanned out to every
    /// registered device after a Mac-side clear). Removes the matching
    /// delivered banners directly through the system-notification seam — the
    /// store may not exist yet on a background wake — while the badge was
    /// already applied by the system from the push's `aps.badge`.
    /// - Parameters:
    ///   - ids: The dismissed stable notification ids from `cmux.dismissedIds`.
    ///   - macDeviceId: The physical Mac that emitted the dismissal.
    ///   - macInstanceTag: The exact app instance that emitted the dismissal.
    public func handleRemoteDismiss(
        ids: [String],
        macDeviceId: String?,
        macInstanceTag: String?
    ) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        diagnosticLog?.recordAppEvent(
            .pushRemoteDismissReceived,
            count: trimmed.count
        )
        await deliveredNotificationClearer.removeDelivered(
            ids: trimmed,
            macDeviceID: macDeviceId,
            instanceTag: macInstanceTag
        )
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
        if let macInstanceTag = workspace.macInstanceTag, !macInstanceTag.isEmpty {
            cmux["macInstanceTag"] = macInstanceTag
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
