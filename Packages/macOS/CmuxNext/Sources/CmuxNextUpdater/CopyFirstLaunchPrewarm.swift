import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A new copy's first launch starts the Chromium framework's first load at `main`, beside AppKit's own start
/// (goal next-launch-instant, CMUX-571).
///
/// The first exec or load of a file no process has run yet costs macOS far more than the next one: on a pool
/// mini a first install from the DMG paid about 1.4 s for the CEF framework's first load, through the first
/// Chromium helper, and only once the launch had built its windows and a page asked for Chromium
/// (scripts/measure/nightly-fresh-launch.sh). ``StagedUpdatePrewarm`` pays it for an update while the person
/// still works; a first install has no earlier process of ours, so this pays it as early as its own `main`:
/// each Chromium helper runs once with `--version` (the first loads the framework), the runs
/// ``StagedUpdatePrewarm/helperRuns(bundle:)`` names, at once and side by side.
///
/// Once per copy: the executable's identity (its path, device and inode; a new copy or an update has
/// another) is kept in `defaults` after the runs end, so a launch of a copy that already ran starts nothing.
/// Nothing is skipped: Gatekeeper and the signature checks run as they always do, only earlier.
public nonisolated struct CopyFirstLaunchPrewarm: Sendable {
    /// The defaults key that keeps the identity of the last copy pre-warmed.
    public static let defaultsKey = "cmux.copyFirstLaunchPrewarm.executable"

    /// The app bundle and its main executable.
    public let bundle: URL
    public let executable: URL

    public init(bundle: URL, executable: URL) {
        self.bundle = bundle
        self.executable = executable
    }

    /// The running app's bundle and executable, or nil when either is unknown.
    public static func main() -> CopyFirstLaunchPrewarm? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return CopyFirstLaunchPrewarm(bundle: Bundle.main.bundleURL, executable: executable)
    }

    /// The executable's identity, `path|device|inode`, or nil when it cannot be read. Blocking: one `lstat`.
    public func identity() -> String? {
        var info = stat()
        guard lstat(executable.path, &info) == 0 else { return nil }
        return "\(executable.path)|\(info.st_dev)|\(info.st_ino)"
    }

    /// What runs now: every helper run when `identity` is not the one `kept` names, else nothing. Blocking:
    /// reads the bundle.
    public func plan(identity: String?, kept: String?) -> [StagedUpdatePrewarm.Run] {
        guard let identity, identity != kept else { return [] }
        return StagedUpdatePrewarm.helperRuns(bundle: bundle)
    }

    /// Starts the pre-warm off the main thread and returns at once. Nobody waits for it; each run is stopped
    /// after `timeout`.
    /// `mark` names the moments the runs start and end (the app's launch marks).
    public func start(defaults: UserDefaults = .standard, processes: AsyncProcess = AsyncProcess(),
                      timeout: Duration = .seconds(20), mark: @escaping @Sendable (String) -> Void = { _ in }) {
        let prewarm = self
        // task-owner: one per launch; ends after the last helper exits (each stopped at its timeout). Its own
        // detached task at the start's priority: the point is to finish before Home's first page asks for Chromium.
        Task.detached(priority: .userInitiated) {
            await prewarm.perform(defaults: defaults, processes: processes, timeout: timeout, mark: mark)
        }
    }

    /// Runs the plan, every helper at once, then keeps this copy's identity. Returns the runs started.
    @discardableResult
    func perform(defaults: UserDefaults, processes: AsyncProcess, timeout: Duration,
                 mark: @Sendable (String) -> Void = { _ in }) async -> Int {
        let identity = identity()
        let runs = plan(identity: identity, kept: defaults.string(forKey: Self.defaultsKey))
        guard let identity, !runs.isEmpty else { return 0 }
        mark("copy_prewarm.start")
        await withTaskGroup(of: Void.self) { group in
            for run in runs {
                group.addTask { _ = try? await processes.run(ProcessRequest(run.executable, run.arguments, timeout: timeout)) }
            }
        }
        mark("copy_prewarm.end")
        defaults.set(identity, forKey: Self.defaultsKey)
        return runs.count
    }
}
