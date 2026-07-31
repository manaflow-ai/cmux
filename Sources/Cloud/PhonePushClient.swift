import CmuxAuthRuntime
import Foundation

/// UserDefaults keys for the phone-forwarding feature. Default OFF: the Mac
/// uploads nothing unless the user explicitly turns it on.
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
        forwardingEnabled = defaults.bool(
            forKey: PhonePushSettings.forwardEnabledKey
        )
        mode = PhoneForwardingMode.fromDefaults(defaults)
        hideContent = defaults.bool(forKey: PhonePushSettings.hideContentKey)
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

    private static let eventTTLSeconds = 120
    private static let maxDismissIDsPerPush = 64

    private let session: URLSession
    private let defaults: UserDefaults
    private let clock: PhonePushClock
    private let queueStore: PhonePushQueueStore
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
        queueStore: PhonePushQueueStore = .live()
    ) {
        self.session = session
        self.defaults = defaults
        self.clock = clock
        self.queueStore = queueStore
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

    static var isForwardingEnabled: Bool {
        UserDefaults.standard.bool(forKey: PhonePushSettings.forwardEnabledKey)
    }

    func configuration(
        defaults settingsDefaults: UserDefaults? = nil
    ) -> PhonePushConfiguration {
        PhonePushConfiguration(defaults: settingsDefaults ?? defaults)
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
        defaults: UserDefaults = .standard
    ) -> PhonePushAdmission {
        guard defaults.bool(forKey: PhonePushSettings.forwardEnabledKey) else {
            return .forwardingDisabled
        }
        let mode = PhoneForwardingMode.fromDefaults(defaults)
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
        let mode = PhoneForwardingMode.fromDefaults(defaults)
        let enabled = defaults.bool(forKey: PhonePushSettings.forwardEnabledKey)
        let gate: PhonePushForwardAdmission
        if mode == .always {
            gate = enabled ? .queued : .disabled
        } else {
            gate = Self.admission(
                enabled: enabled,
                mode: mode,
                presence: presenceCache.decision(from: presenceMonitor)
            )
        }
        guard gate == .queued else { return gate }
        guard let identity = auth?.authenticatedSessionIdentity else {
            return .authenticationUnavailable
        }
        deliveryQueue.retainOnly(
            accountID: identity.accountID,
            generation: identity.generation
        )
        let payload = PhonePushPayload(
            notification: notification,
            macDeviceId: MobileHostIdentity.deviceID(),
            badgeCount: badgeCount,
            hideContent: defaults.bool(forKey: PhonePushSettings.hideContentKey)
        )
        guard let envelope = try? PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds:
                clock.nowEpochSeconds + Self.eventTTLSeconds,
            expectedAccountID: identity.accountID,
            expectedSessionGeneration: identity.generation
        ) else { return .queueFull }
        guard deliveryQueue.enqueue(envelope) else {
            log(result: .retryExhausted, correlationID: envelope.correlationID)
            return .queueFull
        }
        return .queued
    }

    func forwardDismissed(ids: [String], badgeCount: Int) {
        guard defaults.bool(forKey: PhonePushSettings.forwardEnabledKey),
              !ids.isEmpty,
              let identity = auth?.authenticatedSessionIdentity else { return }
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
                workspaceId: nil,
                surfaceId: nil,
                retargetsToLiveSurfaceOwner: false,
                macDeviceId: nil,
                notificationId: nil,
                notificationIds: Array(ids[start..<end]),
                badgeCount: badgeCount,
                hideContent: false
            )
            guard let envelope = try? PhonePushRequestEnvelope(
                payload: payload,
                expirationEpochSeconds:
                    clock.nowEpochSeconds + Self.eventTTLSeconds,
                expectedAccountID: identity.accountID,
                expectedSessionGeneration: identity.generation
            ) else { continue }
            if !deliveryQueue.enqueue(envelope) {
                log(result: .retryExhausted, correlationID: envelope.correlationID)
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
        guard defaults.bool(forKey: PhonePushSettings.forwardEnabledKey) else {
            cancelInMemoryQueue()
            await clearPersistedQueue()
            deliveryQueue.start()
            return
        }
        guard let identity else {
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
            if defaults.bool(forKey: PhonePushSettings.forwardEnabledKey),
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
        NSLog("cmux.phonepush queue_persistence=%@", status.rawValue)
        publishStatusChanged()
    }

    private func publishStatusChanged() {
        NotificationCenter.default.post(
            name: .mobileHostStatusDidChange,
            object: nil
        )
        MobileHostService.emitEvent(
            topic: "phone_push.status.changed",
            payload: [:]
        )
    }

    private func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) async -> PhonePushHTTPResult {
        guard defaults.bool(forKey: PhonePushSettings.forwardEnabledKey) else {
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
                  defaults.bool(forKey: PhonePushSettings.forwardEnabledKey)
            else { return .cancelled }
            guard !envelope.isExpired(at: clock.nowEpochSeconds) else {
                return .expired
            }
            if sessionSnapshot == nil {
                do {
                    let captured = try await auth
                        .authenticatedSessionSnapshot()
                    guard PhonePushDeliveryAuthorization.permits(
                        envelope: envelope,
                        session: captured,
                        sessionIsCurrent: await auth
                            .isAuthenticatedSessionCurrent(captured)
                    ) else { return .staleSession }
                    initialSnapshot = captured
                    sessionSnapshot = captured
                } catch {
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
                }
            }
            guard let currentSessionSnapshot = sessionSnapshot,
                  let initialSnapshot else {
                return .authenticationUnavailable
            }
            let response = await performRequest(
                envelope,
                sessionSnapshot: currentSessionSnapshot,
                allowRefreshedGeneration: refreshedAuthentication
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

    private func performRequest(
        _ envelope: PhonePushRequestEnvelope,
        sessionSnapshot: AuthenticatedSessionSnapshot,
        allowRefreshedGeneration: Bool
    ) async -> (
        result: PhonePushHTTPResult,
        retryAfterSeconds: Int?
    ) {
        guard let auth else { return (.authenticationUnavailable, nil) }
        let current = await auth.isAuthenticatedSessionCurrent(sessionSnapshot)
        let accountMatches = envelope.expectedAccountID == sessionSnapshot.accountID
        let generationMatches = allowRefreshedGeneration
            || envelope.expectedSessionGeneration == sessionSnapshot.generation
        guard current, accountMatches, generationMatches else {
            return (.staleSession, nil)
        }
        guard let url = Self.pushURL() else { return (.invalidResponse, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = envelope.body
        request.setValue(
            "Bearer \(sessionSnapshot.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            sessionSnapshot.refreshToken,
            forHTTPHeaderField: "X-Stack-Refresh-Token"
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
                return (.invalidResponse, nil)
            }
            return (
                PhonePushHTTPResult.decode(
                    statusCode: http.statusCode,
                    data: data
                ),
                PhonePushHTTPResult.retryAfterSeconds(
                    response: http,
                    data: data
                )
            )
        } catch {
            if redirectDelegate.refusedRedirect {
                return (.invalidResponse, nil)
            }
            return (PhonePushHTTPResult.classifyTransportError(error), nil)
        }
    }

    private static func pushURL() -> URL? {
        guard var components = URLComponents(
            url: AuthEnvironment.vmAPIBaseURL,
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
        NSLog(
            "cmux.phonepush correlation=%@ outcome=%@",
            correlationID,
            Self.logValue(result)
        )
    }

    private static func logValue(_ result: PhonePushHTTPResult) -> String {
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
