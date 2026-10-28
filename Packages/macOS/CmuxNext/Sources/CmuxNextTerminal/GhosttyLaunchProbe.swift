public import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// What this launch's terminals need from the disk about Ghostty, looked up once on a launch lane, never
/// on the main thread: the resources folder that has themes and the bundled CLI helper (`GHOSTTY_BIN`).
/// `TERM` is not looked up: new terminals get `xterm-256color` unless the person asks for another
/// (``TerminalTermChoice``, whose entry ``TerminfoLookup`` checks only then).
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

    public init(resources: String?, binary: String?) {
        self.resources = resources
        self.binary = binary
    }

    /// The keys of Ghostty's terminal identity that depend on the disk: `GHOSTTY_RESOURCES_DIR` when a folder
    /// has themes. They go over the app's terminal environment.
    public var terminalEnvironment: [String: String] {
        guard let resources, !resources.isEmpty else { return [:] }
        return ["GHOSTTY_RESOURCES_DIR": resources]
    }

    /// Looks everything up: blocking disk checks, for a lane thread. The checks are seams (a test's own).
    public static func look(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                            fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) },
                            isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }) -> Self {
        Self(resources: GhosttyRuntime.resourcesDirectory(bundle: bundle, environment: environment, fileExists: fileExists),
             binary: GhosttyRuntime.cliHelperPath(bundle: bundle, isExecutable: isExecutable))
    }

    /// Starts `look` on `work`'s files lane. Shells wait for it, so a quit never drops it before it runs
    /// (`.blockShutdown`: every `finished()` returns).
    public static func start(on work: BackgroundWork,
                             look: @escaping @Sendable () -> GhosttyLaunchProbe = { GhosttyLaunchProbe.look() }) -> LaunchRead<GhosttyLaunchProbe> {
        LaunchRead(on: work, shutdown: .blockShutdown, look)
    }
}
