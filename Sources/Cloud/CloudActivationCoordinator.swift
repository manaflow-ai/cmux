import CmuxCloud
import CmuxSettings
import Foundation
import Observation

/// Owns the user's first-use Cloud activation and its persisted marker.
///
/// The existing `cloud.beta.machines.enabled` UserDefaults key is retained as
/// the activation marker so installed users keep their Cloud state. The
/// coordinator is the only new mutation path: it commits that marker, emits
/// the notification consumed by Cloud's registry and tunnel owners, and
/// awaits their shared readiness preparation once.
@MainActor
@Observable
final class CloudActivationCoordinator {
    enum Failure: Equatable, Sendable {
        case requiresPro
        case signInRequired
        case serviceUnavailable
    }

    enum State: Equatable, Sendable {
        case disabled
        case enabling
        case enabled
        case failed(Failure)
        case cancelled
        case unavailable
    }

    static let activationKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey

    private(set) var state: State {
        didSet { if oldValue != state { publishState() } }
    }
    /// True while the optimistic activation is preparing shared Cloud runtime
    /// resources. The normal sidebar stays visible, but owners must defer
    /// Cloud polling and mutating controls until this becomes false.
    private(set) var isPreparing = false

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let isAvailable: @MainActor () -> Bool
    private let prepare: @MainActor () async throws -> Void
    private let cleanup: @MainActor () async -> Void
    @ObservationIgnored var activationTask: Task<Void, Never>?
    private var activationID: UUID?
    @ObservationIgnored var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var observations: [NSObjectProtocol] = []
    @ObservationIgnored private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        isAvailable: @escaping @MainActor () -> Bool = { CloudMachinesFeature.isAvailable },
        prepare: @escaping @MainActor () async throws -> Void,
        cleanup: @escaping @MainActor () async -> Void = {},
        observeChanges: Bool = true
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.isAvailable = isAvailable
        self.prepare = prepare
        self.cleanup = cleanup
        let isPersistedEnabled = defaults.object(forKey: Self.activationKey) as? Bool == true
        self.state = isAvailable()
            ? (isPersistedEnabled ? .enabled : .disabled)
            : .unavailable
        if observeChanges {
            observations = [
                .cmuxFeatureFlagsDidChange,
                RightSidebarBetaFeatureSettings.didChangeNotification,
                ManagedDevicePolicy.didChangeNotification,
                UserDefaults.didChangeNotification,
            ].map { name in
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcile() }
                }
            }
        }
    }

    /// Creates a safe placeholder for views mounted before app composition.
    static func unconfigured() -> CloudActivationCoordinator {
        CloudActivationCoordinator(
            defaults: UserDefaults(suiteName: "cmux.cloud.unconfigured.\(UUID().uuidString)") ?? .standard,
            isAvailable: { false },
            prepare: {},
            observeChanges: false
        )
    }

    // App composition owns this coordinator for the process lifetime. The
    // notification closures weakly capture it, so deinit needs no actor-hop
    // cleanup that Swift 6 would reject from a nonisolated deinitializer.
    deinit {}

    /// Reconciles external flag, policy, and persisted-marker changes.
    func reconcile() {
        guard activationTask == nil else { return }
        guard isAvailable() else {
            state = .unavailable
            return
        }
        let wasEnabled: Bool
        if case .enabled = state {
            wasEnabled = true
        } else {
            wasEnabled = false
        }
        let isPersistedEnabled = defaults.object(forKey: Self.activationKey) as? Bool == true
        if isPersistedEnabled {
            state = .enabled
        } else {
            switch state {
            case .failed, .cancelled:
                // Keep the actionable outcome visible until the user retries.
                return
            case .disabled, .enabling, .enabled, .unavailable:
                state = .disabled
            }
        }
        if wasEnabled, !isPersistedEnabled {
            notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        }
    }

    /// Starts the shared Cloud setup exactly once for the current activation.
    func enable() {
        guard activationTask == nil else { return }
        if case .enabled = state { return }
        guard isAvailable() else {
            state = .unavailable
            return
        }
        // Commit the activation marker before preparation so the normal Cloud
        // sidebar renders immediately. Preparation only warms shared runtime
        // resources; failures roll this optimistic marker back below.
        defaults.set(true, forKey: Self.activationKey)
        notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        state = .enabled
        let id = UUID()
        activationID = id
        isPreparing = true
        let previousCleanup = cleanupTask
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activationID == id {
                    self.activationID = nil
                    self.activationTask = nil
                    self.isPreparing = false
                }
            }
            do {
                // Let the optimistic Cloud sidebar render before activation
                // preparation touches the main-actor registry and network.
                await Task.yield()
                await previousCleanup?.value
                try Task.checkCancellation()
                guard self.activationID == id else { throw CancellationError() }
                try await self.prepare()
                guard !Task.isCancelled, self.activationID == id else { throw CancellationError() }
                guard self.isAvailable() else {
                    self.rollbackOptimisticActivation(for: id)
                    await self.settle(id: id, state: .unavailable)
                    return
                }
            } catch is CancellationError {
                // User cancellation clears activationID first, so settle()
                // ignores it. A cancellation from preparation is a transient
                // service interruption unless the Cloud capability disappeared.
                self.rollbackOptimisticActivation(for: id)
                await self.settle(
                    id: id,
                    state: self.isAvailable() ? .failed(.serviceUnavailable) : .unavailable
                )
            } catch let error as VMClientError {
                self.rollbackOptimisticActivation(for: id)
                await self.settle(
                    id: id,
                    state: self.isAvailable() ? .failed(Self.failure(for: error)) : .unavailable
                )
            } catch {
                self.rollbackOptimisticActivation(for: id)
                await self.settle(
                    id: id,
                    state: self.isAvailable() ? .failed(.serviceUnavailable) : .unavailable
                )
            }
        }
    }

    private func rollbackOptimisticActivation(for id: UUID? = nil) {
        if let id, activationID != id { return }
        guard defaults.object(forKey: Self.activationKey) as? Bool == true else { return }
        defaults.set(false, forKey: Self.activationKey)
        notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
    }

    /// Disables Cloud after preserving its identities and other persisted
    /// configuration. Runtime owners observe the same notification used by the
    /// former Beta Features toggle and stop active work without resetting data.
    func disable() {
        guard activationTask == nil else {
            cancel()
            return
        }
        guard defaults.object(forKey: Self.activationKey) as? Bool == true || state == .enabled else {
            state = isAvailable() ? .disabled : .unavailable
            return
        }
        defaults.set(false, forKey: Self.activationKey)
        notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        state = isAvailable() ? .disabled : .unavailable
        scheduleCleanup(after: nil)
    }

    /// Replays the current state and then emits every transition.
    func activationChanges() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.stateContinuations[id] = continuation
            continuation.yield(self.state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Cancels first-use setup and returns to the disabled state without
    /// touching existing Cloud identities or workspaces.
    func cancel() {
        guard activationTask != nil else { return }
        let task = activationTask
        activationID = nil
        activationTask = nil
        isPreparing = false
        task?.cancel()
        rollbackOptimisticActivation()
        scheduleCleanup(after: task)
        state = .cancelled
    }

    /// Retries a failed or cancelled activation through the same setup path.
    func retry() {
        guard case .enabled = state else {
            enable()
            return
        }
    }

    private func settle(id: UUID, state: State) async {
        guard activationID == id else { return }
        await cleanup()
        guard activationID == id else { return }
        self.state = state
    }

    private func scheduleCleanup(after activationTask: Task<Void, Never>?) {
        let id = UUID()
        cleanupID = id
        let previousCleanup = cleanupTask
        let cleanup = self.cleanup
        cleanupTask = Task { @MainActor [weak self] in
            await previousCleanup?.value
            await cleanup()
            // Stop shared transports immediately, then wait for a
            // cancellation-insensitive preparation closure to unwind before
            // a retry can start. A second stop closes any late resource it
            // managed to acquire while unwinding.
            if let activationTask {
                await activationTask.value
                await cleanup()
            }
            guard let self, self.cleanupID == id else { return }
            self.cleanupID = nil
            self.cleanupTask = nil
        }
    }

    private func publishState() {
        var terminatedIDs: [UUID] = []
        for (id, continuation) in stateContinuations {
            if case .terminated = continuation.yield(state) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            stateContinuations.removeValue(forKey: id)
        }
    }

    private static func failure(for error: VMClientError) -> Failure {
        switch error {
        case .httpStatus(402, _): return .requiresPro
        case .notSignedIn: return .signInRequired
        default: return .serviceUnavailable
        }
    }
}
