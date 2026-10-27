import CmuxNextCompat
import Foundation

/// The user's login environment for this app launch.
///
/// Capturing it runs `$SHELL -l -i`, which takes 5-17 s on some setups, so
/// nothing that connects the app waits for it:
///
/// - `startIfNothingRemembered()` (the top of the launch,
///   `DaemonLauncher.captureLoginEnvironment(after:)`) starts the capture at
///   once (`.userInitiated`) only when no copy is remembered, warm daemon or
///   cold.
/// - `start()` (once startup completes) runs the capture at its caller's
///   priority, so a launch with a remembered copy spawns no shell before
///   startup completes.
/// - `immediate()` (starting the daemon) never waits. It returns this
///   launch's capture when it has finished, else the copy remembered from
///   the last launch (`LoginEnvironmentStore`), else nil (the app's own
///   environment, as when a capture fails) and starts the capture at once
///   (`.userInitiated`): a cold daemon with nothing remembered needs it now.
/// - `value()` (each new terminal's `env`) returns the same without waiting
///   when there is one, else starts the capture at once and waits for it;
///   it gives up after `waitTimeout` so a terminal never waits longer.
///
/// Every successful capture is remembered for the next launch. When the
/// first one times out, a second one runs in the background with
/// `refreshTimeout`, so a shell slower than `waitTimeout` still reaches the
/// remembered copy and the terminals opened after it finishes.
///
/// A memory consumer on its own actor (`login-environment`, through
/// `AsyncMemoryConsumerRegistration`): it holds one environment of a few KB, the store's copy until
/// this launch's capture lands and then the capture (the copy is dropped when the capture lands, and
/// a release drops it too). That one environment is its working set: dropping it would cost every
/// new terminal a login shell, so no limit shrinks it, and the report shows what it holds.
actor LoginEnvironmentCache {
    static let shared = LoginEnvironmentCache(store: .standard(), capture: { timeout in
        await LoginEnvironment.shared.capture(timeout: timeout)
    })

    private let store: LoginEnvironmentStore?
    private let capture: @Sendable (Duration) async -> [String: String]?
    private let waitTimeout: Duration
    private let refreshTimeout: Duration
    private var task: Task<[String: String]?, Never>?
    private var retry: Task<Void, Never>?
    /// This launch's latest successful capture.
    private var captured: [String: String]?
    /// The store's copy, read once (`.some(nil)`: nothing remembered, or the capture replaced it).
    private var remembered: [String: String]??
    /// The registration in the app's memory coordinator, kept on the main actor that makes it.
    private nonisolated let memorySlot = AsyncMemoryConsumerSlot()

    /// `capture` runs the login shell with the given deadline; `store` nil
    /// remembers nothing.
    init(
        store: LoginEnvironmentStore?,
        waitTimeout: Duration = .seconds(5),
        refreshTimeout: Duration = .seconds(30),
        capture: @escaping @Sendable (Duration) async -> [String: String]?
    ) {
        self.store = store
        self.capture = capture
        self.waitTimeout = waitTimeout
        self.refreshTimeout = refreshTimeout
    }

    /// Starts the capture now at the caller's priority (`.utility` once
    /// startup completes); a capture already started is kept.
    func start() { _ = capturing(priority: nil) }

    /// Starts the capture now at `.userInitiated` when no copy is remembered
    /// (the first terminal would else wait for a capture from zero); with
    /// one it waits for ``start()``.
    func startIfNothingRemembered() {
        guard known() == nil else { return }
        _ = capturing(priority: .userInitiated)
    }

    /// Whether this launch's capture started.
    var captureStarted: Bool { task != nil }

    /// Waits for this launch's first capture to end (at once when none started); nil when it failed.
    func captureEnded() async -> [String: String]? {
        guard let task else { return nil }
        return await task.value
    }

    /// The environment for a new terminal: this launch's capture or the
    /// remembered copy at once, else the capture (nil when it failed),
    /// started now when it has not been.
    func value() async -> [String: String]? {
        if let known = known() { return known }
        _ = await capturing(priority: .userInitiated).value
        return captured
    }

    /// The environment for starting the daemon, without waiting for the
    /// login shell: this launch's capture or the remembered copy, else nil,
    /// and then the capture starts at once for the terminals that follow.
    func immediate() -> [String: String]? {
        if let known = known() { return known }
        startIfNothingRemembered()
        return nil
    }

    private func known() -> [String: String]? {
        if let captured { return captured }
        if remembered == nil { remembered = .some(store?.load()) }
        return remembered ?? nil
    }

    /// The capture, started at `priority` (nil: the caller's) when it has not been.
    private func capturing(priority: TaskPriority?) -> Task<[String: String]?, Never> {
        if let task { return task }
        let capture = capture
        let waitTimeout = waitTimeout
        // The capture runs off this actor; only its record comes back to it.
        let task = Task(priority: priority) { @concurrent [self] () -> [String: String]? in
            guard let environment = await capture(waitTimeout) else {
                await refreshInBackground()
                return nil
            }
            await record(environment)
            return environment
        }
        self.task = task
        return task
    }

    private func refreshInBackground() {
        guard retry == nil else { return }
        let capture = capture
        let refreshTimeout = refreshTimeout
        retry = Task { @concurrent [self] in
            if let environment = await capture(refreshTimeout) { await record(environment) }
        }
    }

    private func record(_ environment: [String: String]) {
        captured = environment
        remembered = .some(nil)  // `known()` reads the capture from now on
        store?.save(environment)
    }
}

extension LoginEnvironmentCache: AsyncMemoryConsumer {
    /// One small environment; losing it costs a login shell (1-17 s), so it is its own working set.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossless, recreateCost: .expensive,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: false)

    func updateMemoryLimit(_ limit: MemoryLimit) -> MemoryUsage? {
        usage
    }

    /// Drops the store's copy once this launch's capture is held; keeps the one environment.
    func releaseMemory(downTo limit: MemoryLimit) -> MemoryUsage? {
        if captured != nil { remembered = .some(nil) }
        return usage
    }

    /// The environments held (the capture and the store's copy) and their keys' and values' UTF-8 bytes.
    private var usage: MemoryUsage {
        let held = [captured, remembered ?? nil].compactMap { $0 }
        let bytes = held.reduce(0) { total, environment in
            environment.reduce(total) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
        return MemoryUsage(footprintBytes: bytes, entries: held.count)
    }

    /// Registers the environment with the app's memory coordinator (`login-environment`); the cache
    /// keeps the registration.
    ///
    /// - Parameters:
    ///   - registry: The memory coordinator.
    ///   - hop: How the coordinator's calls leave the main actor (tests pass their own).
    @MainActor func registerMemoryConsumer(with registry: any MemoryConsumerRegistry, hop: AsyncMemoryConsumerHop = .task) {
        memorySlot.register(name: "login-environment", traits: Self.memoryTraits, consumer: self, registry: registry, hop: hop)
    }
}
