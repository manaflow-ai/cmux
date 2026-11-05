import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextWakeups
public import Foundation

/// Thin process adapter: Rust resolves and validates the selected environment before app services start.
public struct CloudEnvironmentBootstrap: Sendable {
    let work: BackgroundWork

    public init(work: BackgroundWork) { self.work = work }

    /// The launch's read, with no network read when it can (`resolve(cacheFirst:)`): the fetch held every launch's
    /// first window up to 1.5 s (cmuxterm-hq#7289). `refresh`, run once the window is up, fetches the backend's
    /// client-config into the cache for the next launch; it does nothing when this read already fetched it.
    public func resolveAtLaunch() async throws -> (selection: CloudRuntimeSelection, refresh: @MainActor () -> Void) {
        let selection = try await resolve(cacheFirst: true)
        guard selection.configSource != "backend" else { return (selection, {}) }
        return (selection, { [self] in
            // task-owner: none needed; one bounded CLI fetch (ProcessRunner's 30 s timeout) that only rewrites the cache.
            Task.detached(priority: .utility) { _ = try? await self.resolve() }
        })
    }

    /// cacheFirst: the launch's read. A validated cached client-config, else a known backend's built-in one, answers
    /// with no network read; only a custom origin with no cache is fetched.
    public func resolve(persisted: Bool = false, cacheFirst: Bool = false) async throws -> CloudRuntimeSelection {
        guard let cli = await BundledExecutable.cli(resources: Bundle.main.resourceURL, work: work).resolve() else {
            throw DaemonError.launchFailed("The bundled cmux CLI is unavailable.")
        }
        var environment = ProcessInfo.processInfo.environment
        // A source CLI override still resolves the actual app's namespace.
        if let bundleID = Bundle.main.bundleIdentifier { environment["CMUX_BUNDLE_ID"] = bundleID }
        let launchArguments = try JSONSerialization.data(withJSONObject: ProcessInfo.processInfo.arguments)
        // timeout: a wedged bundled CLI must not prevent the app from finishing
        // launch; ProcessRunner kills and reaps it so the unavailable fallback runs.
        let result = try await ProcessRunner.run(executable: cli,
            arguments: ["--json", "cloud", "env", "get"] + (cacheFirst ? ["--cache-first"] : []) + (persisted ? ["--persisted"]
                : ["--launch-args", String(decoding: launchArguments, as: UTF8.self)]),
            environment: environment, timeout: .seconds(30), clock: ContinuousClock())
        guard result.status == 0 else {
            throw DaemonError.launchFailed("Could not resolve this app's Cloud environment: " + String(decoding: result.stderr, as: UTF8.self))
        }
        let selection = try CloudRuntimeSelection.decode(result.stdout)
        guard selection.bundleId == Bundle.main.bundleIdentifier else {
            throw DaemonError.launchFailed("The Cloud environment belongs to another app bundle.")
        }
        return selection
    }
    /// Forwards create-option validation to Rust's selected backend capability contract.
    public func checkCreate(backend: URL, params: Data) async throws {
        guard let cli = await BundledExecutable.cli(resources: Bundle.main.resourceURL, work: work).resolve() else {
            throw DaemonError.launchFailed("The bundled cmux CLI is unavailable.")
        }
        var environment = ProcessInfo.processInfo.environment
        if let bundleID = Bundle.main.bundleIdentifier { environment["CMUX_BUNDLE_ID"] = bundleID }
        // timeout: capability validation is a preflight for a user action; a
        // wedged CLI must be killed and reaped so the caller can show failure.
        let result = try await ProcessRunner.run(executable: cli,
            arguments: ["--json", "cloud", "env", "check-create", "--backend", backend.absoluteString,
                        "--params", String(decoding: params, as: UTF8.self)],
            environment: environment, timeout: .seconds(30), clock: ContinuousClock())
        guard result.status == 0 else {
            throw DaemonError.launchFailed(String(decoding: result.stderr, as: UTF8.self))
        }
    }

    public func startRelaunch() async throws -> Int32 {
        guard let cli = await BundledExecutable.cli(resources: Bundle.main.resourceURL, work: work).resolve() else {
            throw DaemonError.launchFailed("The bundled cmux CLI is unavailable.")
        }
        let appPID = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        return try await work.run(.userVisible, mayBlock: .system) {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["cloud", "env", "relaunch", "--pid", String(appPID), "--bundle-path", bundlePath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process.processIdentifier
        }
    }
}
