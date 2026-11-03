import CmuxNextAgentPane
import CmuxNextDaemon
public import Foundation

/// Starts the engine's `optchat-chief move watch --home <home>` (detached) for a Chief home marked
/// moved: while `state/moved.json` exists it carries out the moved Chief's teleport requests and it
/// exits once the Chief is home again. A move the Chief starts launches it itself; after a Mac
/// restart nobody does, so the app starts it when its marker watch sees the home moved (at launch
/// or when the marker appears). A second copy exits at once on `state/move-watch.lock`, so a
/// start while one runs costs one short process.
public struct ChiefMoveWatchLauncher {
    /// The app bundle that carries `Contents/Resources/bin/optchat-chief`.
    private let bundle: Bundle

    /// - Parameter bundle: The bundle with the engine (default: the app's).
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The shell backgrounds the watcher in its own process group (as the Chief host starts), its
    /// output appended to `log`, and exits at once.
    func arguments(tool: String, home: String, log: String) -> [String] {
        ["-c", #"set -m; "$@" >>"$0" 2>&1 </dev/null &"#, log, tool, "move", "watch", "--home", home]
    }

    /// Starts it for `home` with the bundled `optchat-chief`; nothing without it or while agent
    /// launches are off (the build-session kill switch).
    public func start(home: URL) {
        guard !AcpmuxEnvironment.agentLaunchDisabled(), let tool = bundle.resourceURL?.appendingPathComponent("bin/optchat-chief") else { return }
        let log = home.appendingPathComponent("state/move-watch.log").path
        let arguments = arguments(tool: tool.path, home: home.path, log: log)
        // task-owner: none; one file check, then one shell that backgrounds the watcher and exits at once (bounded by its timeout)
        Task.detached(priority: .utility) {
            guard FileManager.checked.isExecutableFile(atPath: tool.path) else { return }
            _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, environment: nil,
                                             timeout: .seconds(10), clock: ContinuousClock())
        }
    }
}
