public import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// What this launch's terminals need from the disk about Ghostty, looked up once on a launch lane, never
/// on the main thread: the resources folder that has themes, the bundled CLI helper (`GHOSTTY_BIN`), and
/// whether the `xterm-ghostty` terminfo entry is installed (`TERM`).
///
/// The app's `main` starts it (``start(on:look:)``); each shell's env and the daemon's `server ensure`
/// await it (CmuxNextApp's `AppEnvironment.ghosttyProbe`). Chrome keeps blocking file checks off its UI
/// thread the same way: they are posted with `base::MayBlock()` (base/task/thread_pool.h), and the UI
/// thread disallows them (base/threading/thread_restrictions.h).
public nonisolated struct GhosttyLaunchProbe: Sendable, Equatable {
    /// The Ghostty resources folder (``GhosttyRuntime/resourcesDirectory(bundle:environment:fileExists:)``); nil when none has themes.
    public var resources: String?
    /// The bundled Ghostty CLI helper (``GhosttyRuntime/cliHelperPath(bundle:isExecutable:)``); nil when this build has none.
    public var binary: String?
    /// `xterm-ghostty` is in a terminfo folder ncurses searches (``hasInstalledTerminfo(home:fileExists:)``).
    public var terminfoInstalled: Bool

    public init(resources: String?, binary: String?, terminfoInstalled: Bool) {
        self.resources = resources
        self.binary = binary
        self.terminfoInstalled = terminfoInstalled
    }

    /// The keys of Ghostty's terminal identity that depend on the disk: `TERM` (`xterm-ghostty` only when
    /// installed: ssh targets, VMs and containers lack the bundled entry), and `GHOSTTY_RESOURCES_DIR` when a
    /// folder has themes. They go over the app's terminal environment.
    public var terminalEnvironment: [String: String] {
        var env = ["TERM": terminfoInstalled ? "xterm-ghostty" : "xterm-256color"]
        if let resources, !resources.isEmpty { env["GHOSTTY_RESOURCES_DIR"] = resources }
        return env
    }

    /// Looks everything up: blocking disk checks, for a lane thread. The checks are seams (a test's own).
    public static func look(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory(),
                            fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) },
                            isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }) -> Self {
        Self(resources: GhosttyRuntime.resourcesDirectory(bundle: bundle, environment: environment, fileExists: fileExists),
             binary: GhosttyRuntime.cliHelperPath(bundle: bundle, isExecutable: isExecutable),
             terminfoInstalled: hasInstalledTerminfo(home: home, fileExists: fileExists))
    }

    /// Whether `xterm-ghostty` is in a terminfo folder ncurses searches by default.
    public static func hasInstalledTerminfo(home: String = NSHomeDirectory(),
                                            fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }) -> Bool {
        let roots = [home + "/.terminfo", "/usr/share/terminfo", "/usr/lib/terminfo", "/etc/terminfo", "/lib/terminfo",
                     "/opt/homebrew/share/terminfo", "/usr/local/share/terminfo"]
        return roots.contains { fileExists($0 + "/78/xterm-ghostty") || fileExists($0 + "/x/xterm-ghostty") }
    }

    /// Starts `look` on `work`'s files lane. Shells wait for it, so a quit never drops it before it runs
    /// (`.blockShutdown`: every `finished()` returns).
    public static func start(on work: BackgroundWork,
                             look: @escaping @Sendable () -> GhosttyLaunchProbe = { GhosttyLaunchProbe.look() }) -> LaunchRead<GhosttyLaunchProbe> {
        LaunchRead(on: work, shutdown: .blockShutdown, look)
    }
}
