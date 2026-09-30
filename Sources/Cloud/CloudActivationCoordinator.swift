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
    private var activationTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        isAvailable: @escaping @MainActor () -> Bool = { CloudMachinesFeature.isAvailable },
        prepare: @escaping @MainActor () async throws -> Void
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.isAvailable = isAvailable
        self.prepare = prepare
        self.state = isAvailable()
            ? (CloudMachinesFeature.localOptIn(defaults: defaults) ? .enabled : .disabled)
            : .unavailable
        observations = [
            .cmuxFeatureFlagsDidChange,
            RightSidebarBetaFeatureSettings.didChangeNotification,
            ManagedDevicePolicy.didChangeNotification,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }

    /// Creates a safe placeholder for views mounted before app composition.
    static func unconfigured() -> CloudActivationCoordinator {
        CloudActivationCoordinator(
            defaults: UserDefaults(suiteName: "cmux.cloud.unconfigured.\(UUID().uuidString)") ?? .standard,
            isAvailable: { false },
            prepare: {}
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
        state = CloudMachinesFeature.localOptIn(defaults: defaults) ? .enabled : .disabled
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
        defaults.set(true, forKey: Self.activationKey)
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activationTask = nil }
            do {
                try await self.prepare()
                guard !Task.isCancelled else { throw CancellationError() }
                self.state = .enabled
            } catch is CancellationError {
                self.state = .cancelled
            } catch let error as VMClientError {
                self.state = .failed(Self.failure(for: error))
            } catch {
                self.state = .failed(.serviceUnavailable)
            }
        }
        notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
    }

    /// Cancels first-use setup and returns to the disabled state without
    /// touching existing Cloud identities or workspaces.
    func cancel() {
        guard activationTask != nil else {
            state = .cancelled
            return
        }
        activationTask?.cancel()
        activationTask = nil
        defaults.set(false, forKey: Self.activationKey)
        notificationCenter.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
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
        guard let activationTask else { return }
        await activationTask.value
    }

    private static func failure(for error: VMClientError) -> Failure {
        switch error {
        case .httpStatus(402, _): return .requiresPro
        case .notSignedIn: return .signInRequired
        default: return .serviceUnavailable
        }
    }
}
