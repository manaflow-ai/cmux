import CmuxAuthRuntime
import Foundation
import Observation
import OSLog

nonisolated private let phonePushLog = Logger(
    subsystem: "ai.manaflow.cmux",
    category: "phone-push"
)

/// UserDefaults keys for the phone-forwarding feature. Missing preferences
/// resolve to enabled + always; an explicit persisted choice remains authoritative.
enum PhonePushSettings {
    static let forwardEnabledKey = "forwardNotificationsToPhone"
    static let hideContentKey = "forwardNotificationsHideContent"
    static let forwardModeKey = "forwardNotificationsToPhoneMode"
}

struct PhonePushConfiguration: Equatable, Sendable {
    let forwardingEnabled: Bool
    let mode: PhoneForwardingMode
    let hideContent: Bool

    init(defaults: UserDefaults) {
        forwardingEnabled = Self.forwardingEnabled(in: defaults)
        mode = PhoneForwardingMode.fromDefaults(defaults)
        hideContent = defaults.bool(forKey: PhonePushSettings.hideContentKey)
    }

    static func forwardingEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: PhonePushSettings.forwardEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: PhonePushSettings.forwardEnabledKey)
    }
}

/// Observable projection of the Mac-owned forwarding settings.
@MainActor
@Observable
final class PhonePushConfigurationState {
    fileprivate(set) var configuration: PhonePushConfiguration

    init(configuration: PhonePushConfiguration) {
        self.configuration = configuration
    }
}

enum PhonePushQueuePersistenceStatus: String, Equatable, Sendable {
    case unknown
    case healthy
    case loadFailed = "load_failed"
    case saveFailed = "save_failed"
    case clearFailed = "clear_failed"
}

/// Sanitized result of applying the Mac's live forwarding gate.
enum PhonePushAdmission: String, Equatable, Sendable {
    case allowed
    case forwardingDisabled = "forwarding_disabled"
    case suppressedMacActive = "suppressed_mac_active"
    case unknown
}

/// Durable, bounded Mac-to-phone push producer.
@MainActor
final class PhonePushClient {
    static let shared = PhonePushClient()

    static let settingsDidChangeNotification = Notification.Name(
        "PhonePushClient.settingsDidChange"
    )

    private static let eventTTLSeconds = 120
    // The route permits 64 ids, but each opaque id may be 200 UTF-16 units and
    // JSON control-character escaping can expand each unit to six bytes. Four
    // keeps every valid batch under the shared 8 KiB request bound.
    private static let maxDismissIDsPerPush = 4
    nonisolated static let requestTimeoutInterval: TimeInterval = 35

    private let session: URLSession
    private let defaults: UserDefaults
    private let clock: PhonePushClock
    private let queueStore: PhonePushQueueStore
    private let deliveryAuthorization: PhonePushDeliveryAuthorization
    let configurationState: PhonePushConfigurationState
    private var auth: AuthCoordinator?
    var presenceMonitor: MacPresenceMonitor = .live()
    private var presenceCache = MacPresenceDecisionCache()
    private var authLifecycleTask: Task<Void, Never>?
    private var activeIdentity: AuthenticatedSessionIdentity?
    private var pendingPersistenceSnapshot: [PhonePushRequestEnvelope]?
    private var persistenceTask: Task<Void, Never>?
    private var suppressQueuePersistence = false
    private(set) var lastDeliveryResult: PhonePushHTTPResult?
    private(set) var queuePersistenceStatus: PhonePushQueuePersistenceStatus =
        .unknown

    private lazy var deliveryQueue = PhonePushSerialDeliveryQueue(
        startsImmediately: false,
        pendingChanged: { [weak self] snapshot in
            guard self?.suppressQueuePersistence == false else { return }
            self?.schedulePersistence(snapshot)
        },
        sender: { [weak self] envelope in
            guard let self else { return .cancelled }
            let result = await self.deliver(envelope)
            self.lastDeliveryResult = result
            self.log(result: result, correlationID: envelope.correlationID)
            return result
        }
    )

    private init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        clock: PhonePushClock = .live,
        queueStore: PhonePushQueueStore = .live(),
        deliveryAuthorization: PhonePushDeliveryAuthorization = .init()
    ) {
        self.session = session
        self.defaults = defaults
        self.clock = clock
        self.queueStore = queueStore
        self.deliveryAuthorization = deliveryAuthorization
        self.configurationState = PhonePushConfigurationState(
            configuration: PhonePushConfiguration(defaults: defaults)
        )
    }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authLifecycleTask?.cancel()
        cancelInMemoryQueue()
        activeIdentity = nil
        authLifecycleTask = Task { [weak self, weak auth] in
            guard let self, let auth else { return }
            await self.bootstrapQueueAndObserve(auth: auth)
        }
    }

    func configuration(
        defaults settingsDefaults: UserDefaults? = nil
    ) -> PhonePushConfiguration {
        PhonePushConfiguration(defaults: settingsDefaults ?? defaults)
    }

    /// Reconciles state after another owner removes stored overrides (Reset All).
    func reloadConfigurationFromDefaults() {
        let configuration = PhonePushConfiguration(defaults: defaults)
        configurationState.configuration = configuration
        if !configuration.forwardingEnabled {
            cancelPendingDeliveries()
        }
        NotificationCenter.default.post(
            name: Self.settingsDidChangeNotification,
            object: self
        )
        publishStatusChanged()
    }

    /// Sole mutation path for Mac and phone callers. Validation happens before
    /// entry; all three privacy fields publish as one main-actor transaction.
    @discardableResult
    func updateSettings(
        forwardingEnabled: Bool? = nil,
        mode: PhoneForwardingMode? = nil,
        hideContent: Bool? = nil,
        defaults settingsDefaults: UserDefaults? = nil
    ) -> PhonePushConfiguration {
        let settingsDefaults = settingsDefaults ?? defaults
        if let forwardingEnabled {
            settingsDefaults.set(
                forwardingEnabled,
                forKey: PhonePushSettings.forwardEnabledKey
            )
        }
        if let mode {
            settingsDefaults.set(
                mode.rawValue,
                forKey: PhonePushSettings.forwardModeKey
            )
        }
        if let hideContent {
            settingsDefaults.set(
                hideContent,
                forKey: PhonePushSettings.hideContentKey
            )
        }
        let configuration = PhonePushConfiguration(defaults: settingsDefaults)
        if settingsDefaults === defaults {
            configurationState.configuration = configuration
            NotificationCenter.default.post(
                name: Self.settingsDidChangeNotification,
                object: self
            )
        }
        if !configuration.forwardingEnabled {
            cancelPendingDeliveries()
        }
        publishStatusChanged()
        return configuration
    }

    nonisolated static func shouldForward(
        mode: PhoneForwardingMode,
        presence: MacPresenceMonitor.Decision
    ) -> Bool {
        switch mode {
        case .always:
            return true
        case .onlyWhenAway:
            return !presence.isActive
        }
    }

    nonisolated static func admission(
        enabled: Bool,
        mode: PhoneForwardingMode,
        presence: MacPresenceMonitor.Decision
    ) -> PhonePushForwardAdmission {
        guard enabled else { return .disabled }
        return shouldForward(mode: mode, presence: presence)
            ? .queued
            : .presenceSuppressed
    }

    func currentAdmission(
        defaults settingsDefaults: UserDefaults? = nil
    ) -> PhonePushAdmission {
        let settingsDefaults = settingsDefaults ?? defaults
        guard PhonePushConfiguration.forwardingEnabled(in: settingsDefaults) else {
            return .forwardingDisabled
        }
        let mode = PhoneForwardingMode.fromDefaults(settingsDefaults)
        guard mode != .always else { return .allowed }
        let presence = presenceCache.decision(from: presenceMonitor)
        return Self.shouldForward(mode: mode, presence: presence)
            ? .allowed
            : .suppressedMacActive
    }

    @discardableResult
    func forward(
        _ notification: TerminalNotification,
        badgeCount: Int
    ) -> PhonePushForwardAdmission {
        let gate = forwardingAdmission()
        guard gate == .queued else { return gate }
        let payload = PhonePushPayload(
            notification: notification,
            macDeviceId: MobileHostIdentity.deviceID(),
            badgeCount: badgeCount,
            hideContent: defaults.bool(forKey: PhonePushSettings.hideContentKey)
        )
        return enqueue(payload)
    }

    /// Enqueues a user-requested diagnostic alert through the production path.
    /// The response confirms queue admission only; backend and APNs outcomes
    /// remain asynchronous and are correlated by the envelope UUID.
    func forwardTest(badgeCount: Int) -> PhonePushForwardAdmission {
        let gate = forwardingAdmission()
        guard gate == .queued else { return gate }
        let payload = PhonePushPayload(
            kind: .notify,
            title: String(
                localized: "push.test.title",
                defaultValue: "cmux Notification Test"
            ),
            subtitle: "",
            body: String(
                localized: "push.test.body",
                defaultValue: "Your Mac sent a test alert to cmux."
            ),
            replyShape: "",
            workspaceId: nil,
            surfaceId: nil,
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: MobileHostIdentity.deviceID(),
            notificationId: nil,
            notificationIds: [],
            badgeCount: badgeCount,
            hideContent: defaults.bool(forKey: PhonePushSettings.hideContentKey)
        )
        return enqueue(payload)
    }

    private func forwardingAdmission() -> PhonePushForwardAdmission {
        let mode = PhoneForwardingMode.fromDefaults(defaults)
        let enabled = PhonePushConfiguration.forwardingEnabled(in: defaults)
        if mode == .always {
            return enabled ? .queued : .disabled
        }
        return Self.admission(
            enabled: enabled,
            mode: mode,
            presence: presenceCache.decision(from: presenceMonitor)
        )
    }

    private func enqueue(
        _ payload: PhonePushPayload
    ) -> PhonePushForwardAdmission {
        guard let identity = auth?.authenticatedSessionIdentity else {
            return .authenticationUnavailable
        }
        guard let targetBundleIdentifier = MobileIOSPairingTargetStore()
            .pushTargetNamespace?.bundleIdentifier else {
            return .encodingFailed
        }
        deliveryQueue.retainOnly(
            accountID: identity.accountID,
            generation: identity.generation
        )
        let correlationID = UUID()
        let envelope: PhonePushRequestEnvelope
        do {
            envelope = try PhonePushRequestEnvelope(
                payload: payload,
                correlationID: correlationID,
                expirationEpochSeconds:
                    clock.nowEpochSeconds + Self.eventTTLSeconds,
                expectedAccountID: identity.accountID,
                expectedSessionGeneration: identity.generation,
                targetBundleIdentifier: targetBundleIdentifier
            )
        } catch {
            logQueueStage(
                "encoding_failed",
                correlationID: correlationID.uuidString.lowercased()
            )
            return .encodingFailed
        }
        guard deliveryQueue.enqueue(envelope) else {
            logQueueStage("queue_overflow", correlationID: envelope.correlationID)
            return .queueFull
        }
        return .queued
    }

    func forwardDismissed(ids: [String], badgeCount: Int) {
        guard PhonePushConfiguration.forwardingEnabled(in: defaults),
              !ids.isEmpty,
              let identity = auth?.authenticatedSessionIdentity,
              let targetBundleIdentifier = MobileIOSPairingTargetStore()
                  .pushTargetNamespace?.bundleIdentifier else { return }
        deliveryQueue.retainOnly(
            accountID: identity.accountID,
            generation: identity.generation
        )
        for start in stride(
            from: 0,
            to: ids.count,
            by: Self.maxDismissIDsPerPush
        ) {
            let end = min(start + Self.maxDismissIDsPerPush, ids.count)
            let payload = PhonePushPayload(
                kind: .dismiss,
                title: "",
                subtitle: "",
                body: "",
                replyShape: "",
                workspaceId: nil,
                surfaceId: nil,
                retargetsToLiveSurfaceOwner: false,
                macDeviceId: nil,
                notificationId: nil,
                notificationIds: Array(ids[start..<end]),
                badgeCount: badgeCount,
                hideContent: false
            )
            let correlationID = UUID()
            let envelope: PhonePushRequestEnvelope
            do {
                envelope = try PhonePushRequestEnvelope(
                    payload: payload,
                    correlationID: correlationID,
                    expirationEpochSeconds:
                        clock.nowEpochSeconds + Self.eventTTLSeconds,
                    expectedAccountID: identity.accountID,
                    expectedSessionGeneration: identity.generation,
                    targetBundleIdentifier: targetBundleIdentifier
                )
            } catch {
                logQueueStage(
                    "dismiss_encoding_failed",
                    correlationID: correlationID.uuidString.lowercased()
                )
                continue
            }
            if !deliveryQueue.enqueuePrioritizingDismiss(envelope) {
                logQueueStage(
                    "dismiss_queue_overflow",
                    correlationID: envelope.correlationID
                )
            }
        }
    }

    /// Cancels in-flight retries and atomically clears credential-free storage.
    func cancelPendingDeliveries() {
        cancelInMemoryQueue()
        pendingPersistenceSnapshot = []
        schedulePersistence([])
    }

    private func bootstrapQueueAndObserve(auth: AuthCoordinator) async {
        // This call waits for launch bootstrap. A transient token failure does
        // not erase credential-free queue ownership; the published identity
        // below remains authoritative until a real auth transition.
        auth.start()
        _ = try? await auth.authenticatedSessionSnapshot()
        guard !Task.isCancelled, self.auth === auth else { return }
        await restoreQueueIfAllowed(
            identity: auth.authenticatedSessionIdentity,
            auth: auth
        )
        guard !Task.isCancelled, self.auth === auth else { return }
        let identities = auth.authenticatedSessionIdentities()
        for await identity in identities {
            guard !Task.isCancelled, self.auth === auth else { return }
            await handleAuthTransition(identity, auth: auth)
        }
    }

    private func restoreQueueIfAllowed(
        identity: AuthenticatedSessionIdentity?,
        auth: AuthCoordinator
    ) async {
        guard PhonePushConfiguration.forwardingEnabled(in: defaults) else {
            // Adopt the observed identity so the identity stream's initial
            // yield is a no-op instead of a spurious auth transition that
            // cancels work enqueued between restore and first yield.
            activeIdentity = identity
            cancelInMemoryQueue()
            await clearPersistedQueue()
            deliveryQueue.start()
            return
        }
        guard let identity else {
            activeIdentity = nil
            cancelInMemoryQueue()
            await clearPersistedQueue()
            deliveryQueue.start()
            return
        }
        let restored: [PhonePushRequestEnvelope]
        do {
            restored = try await queueStore.load(
                nowEpochSeconds: clock.nowEpochSeconds
            )
            setQueuePersistenceStatus(.healthy)
        } catch {
            restored = []
            setQueuePersistenceStatus(.loadFailed)
        }
        guard !Task.isCancelled,
              self.auth === auth,
              auth.isAuthenticatedSessionIdentityCurrent(identity) else {
            return
        }
        let rebound = restored.compactMap { envelope -> PhonePushRequestEnvelope? in
            guard envelope.expectedAccountID == identity.accountID else {
                return nil
            }
            return envelope.rebound(
                accountID: identity.accountID,
                generation: identity.generation
            )
        }
        deliveryQueue.restore(rebound)
        deliveryQueue.retainOnly(
            accountID: identity.accountID,
            generation: identity.generation
        )
        activeIdentity = identity
        deliveryQueue.start()
    }

    private func handleAuthTransition(
        _ identity: AuthenticatedSessionIdentity?,
        auth: AuthCoordinator
    ) async {
        guard identity != activeIdentity else { return }
        cancelInMemoryQueue()
        pendingPersistenceSnapshot = []
        activeIdentity = identity
        await clearPersistedQueue()
        guard self.auth === auth else { return }
        deliveryQueue.start()
    }

    private func schedulePersistence(
        _ snapshot: [PhonePushRequestEnvelope]
    ) {
        pendingPersistenceSnapshot = snapshot
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            await self?.drainPersistence()
        }
    }

    private func cancelInMemoryQueue() {
        suppressQueuePersistence = true
        deliveryQueue.cancelAll()
        suppressQueuePersistence = false
    }

    private func drainPersistence() async {
        while let snapshot = pendingPersistenceSnapshot {
            pendingPersistenceSnapshot = nil
            if PhonePushConfiguration.forwardingEnabled(in: defaults),
               !snapshot.isEmpty {
                do {
                    try await queueStore.save(snapshot)
                    setQueuePersistenceStatus(.healthy)
                } catch {
                    setQueuePersistenceStatus(.saveFailed)
                }
            } else {
                await clearPersistedQueue()
            }
        }
        persistenceTask = nil
    }

    private func clearPersistedQueue() async {
        do {
            try await queueStore.clear()
            setQueuePersistenceStatus(.healthy)
        } catch {
            setQueuePersistenceStatus(.clearFailed)
        }
    }

    private func setQueuePersistenceStatus(
        _ status: PhonePushQueuePersistenceStatus
    ) {
        guard queuePersistenceStatus != status else { return }
        queuePersistenceStatus = status
        phonePushLog.info(
            "queue_persistence=\(status.rawValue, privacy: .public)"
        )
        publishStatusChanged()
    }

    private func publishStatusChanged() {
        MobileHostService.emitEvent(
            topic: "phone_push.status.changed",
            payload: [:]
        )
    }

    private func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) async -> PhonePushHTTPResult {
        guard PhonePushConfiguration.forwardingEnabled(in: defaults) else {
            return .cancelled
        }
        guard !envelope.isExpired(at: clock.nowEpochSeconds) else {
            return .expired
        }
        guard let auth else { return .authenticationUnavailable }
        var initialSnapshot: AuthenticatedSessionSnapshot?
        var sessionSnapshot: AuthenticatedSessionSnapshot?
        var refreshedAuthentication = false
        var attempt = 1
        while attempt <= PhonePushRetryPolicy.maximumAttempts {
            guard !Task.isCancelled,
                  PhonePushConfiguration.forwardingEnabled(in: defaults)
            else { return .cancelled }
            guard !envelope.isExpired(at: clock.nowEpochSeconds) else {
                return .expired
            }
            if sessionSnapshot == nil {
                do {
                    let captured = try await auth
                        .authenticatedSessionSnapshot()
                    guard deliveryAuthorization.permits(
                        envelope: envelope,
                        session: captured,
                        sessionIsCurrent: await auth
                            .isAuthenticatedSessionCurrent(captured)
                    ) else { return .staleSession }
                    initialSnapshot = captured
                    sessionSnapshot = captured
                } catch AuthError.networkError {
                    guard let delay = PhonePushRetryPolicy.delaySeconds(
                        afterAttempt: attempt,
                        result: .authenticationUnavailable,
                        retryAfterSeconds: nil,
                        nowEpochSeconds: clock.nowEpochSeconds,
                        expirationEpochSeconds:
                            envelope.expirationEpochSeconds
                    ) else {
                        return envelope.isExpired(at: clock.nowEpochSeconds)
                            ? .expired
                            : .retryExhausted
                    }
                    do {
                        try await clock.sleep(for: .seconds(delay))
                    } catch {
                        return .cancelled
                    }
                    attempt += 1
                    continue
                } catch {
                    return .authenticationRequired
                }
            }
            guard let currentSessionSnapshot = sessionSnapshot,
                  let initialSnapshot else {
                return .authenticationUnavailable
            }
            let response = await Self.performRequest(
                envelope,
                sessionSnapshot: currentSessionSnapshot,
                auth: auth,
                session: session
            )
            if response.result == .authenticationRequired,
               !refreshedAuthentication {
                do {
                    _ = try await auth.forceRefreshAccessToken()
                    let refreshed = try await auth.authenticatedSessionSnapshot()
                    guard refreshed.accountID == initialSnapshot.accountID,
                          refreshed.accountID == envelope.expectedAccountID,
                          await auth.isAuthenticatedSessionCurrent(refreshed)
                    else { return .staleSession }
                    sessionSnapshot = refreshed
                    refreshedAuthentication = true
                    continue
                } catch AuthError.networkError {
                    guard let delay = PhonePushRetryPolicy.delaySeconds(
                        afterAttempt: attempt,
                        result: .authenticationUnavailable,
                        retryAfterSeconds: nil,
                        nowEpochSeconds: clock.nowEpochSeconds,
                        expirationEpochSeconds: envelope.expirationEpochSeconds
                    ) else {
                        return envelope.isExpired(at: clock.nowEpochSeconds)
                            ? .expired
                            : .retryExhausted
                    }
                    do {
                        try await clock.sleep(for: .seconds(delay))
                    } catch {
                        return .cancelled
                    }
                    attempt += 1
                    continue
                } catch {
                    return .authenticationRequired
                }
            }
            guard response.result.shouldRetry else { return response.result }
            guard let delay = PhonePushRetryPolicy.delaySeconds(
                afterAttempt: attempt,
                result: response.result,
                retryAfterSeconds: response.retryAfterSeconds,
                nowEpochSeconds: clock.nowEpochSeconds,
                expirationEpochSeconds: envelope.expirationEpochSeconds
            ) else {
                return envelope.isExpired(at: clock.nowEpochSeconds)
                    ? .expired
                    : .retryExhausted
            }
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return .cancelled
            }
            attempt += 1
        }
        return .retryExhausted
    }

    /// Explicit executor hop for URL loading. Queue ownership remains on the
    /// main actor, while request construction, I/O, and response decoding do
    /// not consume its executor.
#if compiler(>=6.2)
    @concurrent
#endif
    nonisolated private static func performRequest(
        _ envelope: PhonePushRequestEnvelope,
        sessionSnapshot: AuthenticatedSessionSnapshot,
        auth: AuthCoordinator,
        session: URLSession
    ) async -> (
        result: PhonePushHTTPResult,
        retryAfterSeconds: Int?
    ) {
        let current = await auth.isAuthenticatedSessionCurrent(sessionSnapshot)
        let accountMatches = envelope.expectedAccountID == sessionSnapshot.accountID
        let generationMatches =
            envelope.expectedSessionGeneration == sessionSnapshot.generation
        guard current, accountMatches, generationMatches else {
            return (.staleSession, nil)
        }
        guard let targetBundleIdentifier = envelope.targetBundleIdentifier,
              !targetBundleIdentifier.isEmpty else {
            return (.invalidResponse, nil)
        }
        guard let url = pushURL() else { return (.invalidResponse, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutInterval
        request.httpBody = envelope.body
        request.setValue(
            "Bearer \(sessionSnapshot.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            sessionSnapshot.refreshToken,
            forHTTPHeaderField: "X-Stack-Refresh-Token"
        )
        request.setValue(
            targetBundleIdentifier,
            forHTTPHeaderField: "X-Cmux-IOS-Target-Namespace"
        )
        // Intentionally omit X-Cmux-Team-Id. The push route fans out by the
        // authenticated Stack user id, so a team-picker change cannot retarget
        // an already-created or in-flight notification request.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let redirectDelegate = RedirectMethodPreservingDelegate()
        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: redirectDelegate
            )
            guard await auth.isAuthenticatedSessionCurrent(sessionSnapshot)
            else { return (.staleSession, nil) }
            guard let http = response as? HTTPURLResponse else {
                phonePushLog.error("delivery attempt got a non-HTTP response")
                return (.invalidResponse, nil)
            }
            let decoded = PhonePushHTTPResult.decode(
                statusCode: http.statusCode,
                data: data
            )
            // Status/host/byte-count only — never response content. This is
            // the one place the queue can attribute an outcome to what the
            // server actually said, so keep it at info alongside outcomes.
            phonePushLog.info(
                "delivery attempt host=\(url.host ?? "-", privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) outcome=\(Self.logValue(decoded), privacy: .public)"
            )
            return (
                decoded,
                PhonePushHTTPResult.retryAfterSeconds(
                    response: http,
                    data: data
                )
            )
        } catch {
            if redirectDelegate.refusedRedirect {
                phonePushLog.error("delivery attempt refused a redirect")
                return (.invalidResponse, nil)
            }
            let urlErrorCode = (error as? URLError)?.code.rawValue ?? 0
            phonePushLog.info(
                "delivery attempt host=\(url.host ?? "-", privacy: .public) transport error code=\(urlErrorCode, privacy: .public)"
            )
            return (PhonePushHTTPResult.classifyTransportError(error), nil)
        }
    }

    nonisolated private static func pushURL() -> URL? {
        guard var components = URLComponents(
            url: AuthEnvironment.pushAPIBaseURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        components.host?.isEmpty == false else { return nil }
        components.path = (components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path) + "/api/notifications/push"
        return components.url
    }

    private func log(
        result: PhonePushHTTPResult,
        correlationID: String
    ) {
        phonePushLog.info(
            "correlation=\(correlationID, privacy: .public) outcome=\(Self.logValue(result), privacy: .public)"
        )
    }

    private func logQueueStage(_ stage: String, correlationID: String) {
        phonePushLog.info(
            "correlation=\(correlationID, privacy: .public) outcome=\(stage, privacy: .public)"
        )
    }

    nonisolated private static func logValue(_ result: PhonePushHTTPResult) -> String {
        switch result {
        case .accepted: "accepted"
        case .partial: "partial"
        case .noRegisteredDevices: "no_registered_devices"
        case .retryableFailure: "retryable_failure"
        case .retryExhausted: "retry_exhausted"
        case .authenticationRequired: "authentication_required"
        case .authenticationUnavailable: "authentication_unavailable"
        case .staleSession: "stale_session"
        case .correlationConflict: "correlation_conflict"
        case .expired: "expired"
        case .invalidResponse: "invalid_response"
        case .rejected: "rejected"
        case .cancelled: "cancelled"
        }
    }
}
