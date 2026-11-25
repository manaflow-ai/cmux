public import CmuxNextCompat
public import Foundation

/// A tagged DEV build's reaper (https://github.com/manaflow-ai/cmux/issues/55842): the bundled
/// `cmux-tui __dev-reaper`, started detached at launch. It waits for this app's process to exit,
/// however it exits (Cmd-Q, the end-sessions quit, `reload.sh`'s SIGTERM, a crash, SIGKILL), then
/// ends every process whose command line names this bundle and their descendants: the terminal
/// owner, acpmux, the Chief host, `cmux-files-host`, shells and agents (`dev_reaper.rs`). A
/// shipped app keeps its helpers across a quit on purpose; a tagged DEV build left them running
/// for every build an agent made.
///
/// Only a tagged DEV bundle (`com.cmuxterm.app.debug.<tag>`, not the NEXT DEV daily `.next`)
/// starts it. `CMUX_DEV_KEEP_HELPERS=1` in the app's environment keeps the helpers, for testing
/// that terminals survive a quit.
public struct DevBuildReaper: Sendable, Equatable {
    public static let keepHelpersKey = "CMUX_DEV_KEEP_HELPERS"
    static let developmentBundlePrefix = "com.cmuxterm.app.debug."
    /// The NEXT DEV daily, a Release build people run as their app.
    static let dailyTag = "next"
    static let tool = "Contents/Resources/bin/cmux-tui"

    /// The bundled `cmux-tui`.
    public let executable: URL
    /// The app bundle whose tree it ends.
    public let bundle: URL
    /// The bundle id, which the build's terminal holders and hosts name as their owner.
    public let bundleIdentifier: String
    /// The bundle id's tag.
    public let tag: String

    /// The reaper of the app at `bundleURL`, or nil when this build keeps its helpers.
    public init?(bundleURL: URL, bundleIdentifier: String?, environment: [String: String],
                 isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }) {
        guard environment[Self.keepHelpersKey] != "1",
              let bundleIdentifier, bundleIdentifier.hasPrefix(Self.developmentBundlePrefix)
        else { return nil }
        let tag = String(bundleIdentifier.dropFirst(Self.developmentBundlePrefix.count))
        guard !tag.isEmpty, tag != Self.dailyTag, bundleURL.pathExtension == "app" else { return nil }
        let executable = bundleURL.appendingPathComponent(Self.tool)
        guard isExecutable(executable.path) else { return nil }
        self.executable = executable
        self.bundle = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.tag = tag
    }

    /// This app's reaper, or nil.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> DevBuildReaper? {
        DevBuildReaper(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier, environment: environment)
    }

    /// The shell backgrounds the reaper in its own process group, so the app's quit never signals
    /// it, with its output appended to `log`, and exits at once.
    func arguments(appPID: Int32, log: String) -> [String] {
        ["-c", #"set -m; "$@" >>"$0" 2>&1 </dev/null &"#, log,
         executable.path, "__dev-reaper", "--app-pid", String(appPID), "--bundle", bundle.standardizedFileURL.path,
         "--bundle-id", bundleIdentifier]
    }

    /// The reaper's log, beside the tag's other `/tmp` files.
    var log: String { NSTemporaryDirectory() + "cmux-dev-reaper-\(tag).log" }

    /// Starts the reaper for this process.
    public func start(appPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let arguments = arguments(appPID: appPID, log: log)
        // task-owner: none; one shell that backgrounds the reaper and exits at once (bounded by its timeout)
        Task.detached(priority: .utility) {
            _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, environment: nil,
                                             timeout: .seconds(10), clock: ContinuousClock())
        }
    }
}
