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
    enum Failure: Equatable {
        case requiresPro
        case signInRequired
        case serviceUnavailable
    }

    enum State: Equatable {
        case disabled
        case enabling
        case enabled
        case failed(Failure)
        case cancelled
        case unavailable
    }

    static let activationKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey

    private(set) var state: State

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let isAvailable: @MainActor () -> Bool
    private let prepare: @MainActor () async throws -> Void
    private let cleanup: @MainActor () async -> Void
    private var activationTask: Task<Void, Never>?
    private var activationID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var observations: [NSObjectProtocol] = []

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
        state = .enabling
        let id = UUID()
        activationID = id
        let previousCleanup = cleanupTask
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activationID == id {
                    self.activationID = nil
                    self.activationTask = nil
                }
            }
            do {
                await previousCleanup?.value
                try Task.checkCancellation()
                guard self.activationID == id else { throw CancellationError() }
                try await self.prepare()
                guard !Task.isCancelled, self.activationID == id else { throw CancellationError() }
                guard self.isAvailable() else {
                    await self.settle(id: id, state: .unavailable)
                    return
                }
                self.defaults.set(true, forKey: Self.activationKey)
                self.notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
                self.state = .enabled
            } catch is CancellationError {
                await self.settle(id: id, state: .cancelled)
            } catch let error as VMClientError {
                await self.settle(
                    id: id,
                    state: self.isAvailable() ? .failed(Self.failure(for: error)) : .unavailable
                )
            } catch {
                await self.settle(
                    id: id,
                    state: self.isAvailable() ? .failed(.serviceUnavailable) : .unavailable
                )
            }
        }
    }

    /// Cancels first-use setup and returns to the disabled state without
    /// touching existing Cloud identities or workspaces.
    func cancel() {
        guard activationTask != nil else {
            state = .cancelled
            return
        }
        let task = activationTask
        activationID = nil
        activationTask = nil
        task?.cancel()
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

    /// Waits for the current activation attempt to settle. The sidebar does
    /// not need this, but composition and behavior tests can await the same
    /// task without polling or sleeping.
    func waitForActivation() async {
        await activationTask?.value
        await cleanupTask?.value
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
        let cleanup = self.cleanup
        cleanupTask = Task { @MainActor [weak self] in
            await cleanup()
            // Stop shared transports immediately, then wait for a
            // cancellation-insensitive preparation closure to unwind before
            // a retry can start. A second stop closes any late resource it
            // managed to acquire while unwinding.
            await activationTask?.value
            await cleanup()
            guard let self, self.cleanupID == id else { return }
            self.cleanupID = nil
            self.cleanupTask = nil
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
