import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation

/// What this launch's terminals need from the disk about Ghostty, looked up once on a launch lane, never
/// on the main thread: the resources folder that has themes, the bundled CLI helper (`GHOSTTY_BIN`), and
/// whether the `xterm-ghostty` terminfo entry is installed (`TERM`).
///
/// `main` starts it (``start(on:)``) and keeps it in ``AppEnvironment/ghosttyProbe``; each shell's env
/// (``AppEnvironment/terminalEnvironmentProvider(login:settings:)``) and the daemon's `server ensure`
/// (``AppEnvironment/resolvedTerminalEnvironment()``) await it. Chrome keeps blocking file checks off its UI
/// thread the same way: they are posted with `base::MayBlock()` (base/task/thread_pool.h), and the UI
/// thread disallows them (base/threading/thread_restrictions.h).
nonisolated struct GhosttyLaunchProbe: Sendable, Equatable {
    /// The Ghostty resources folder (``GhosttyRuntime/resourcesDirectory(bundle:environment:fileExists:)``); nil when none has themes.
    var resources: String?
    /// The bundled Ghostty CLI helper (``GhosttyRuntime/cliHelperPath(bundle:isExecutable:)``); nil when this build has none.
    var binary: String?
    /// `xterm-ghostty` is in a terminfo folder ncurses searches (``TerminalEnvironment/hasInstalledGhosttyTerminfo(home:fileExists:)``).
    var terminfoInstalled: Bool

    /// The keys of Ghostty's terminal identity that depend on the disk: `TERM`, and
    /// `GHOSTTY_RESOURCES_DIR` when a folder has themes. They go over ``AppEnvironment/terminalEnvironment``.
    var terminalEnvironment: [String: String] {
        TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: nil, terminfoInstalled: terminfoInstalled)
            .filter { $0.key == "TERM" || $0.key == "GHOSTTY_RESOURCES_DIR" }
    }

    /// Looks everything up: blocking disk checks, for a lane thread. The checks are seams (a test's own).
    static func look(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = NSHomeDirectory(),
                     fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) },
                     isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }) -> Self {
        Self(resources: GhosttyRuntime.resourcesDirectory(bundle: bundle, environment: environment, fileExists: fileExists),
             binary: GhosttyRuntime.cliHelperPath(bundle: bundle, isExecutable: isExecutable),
             terminfoInstalled: TerminalEnvironment.hasInstalledGhosttyTerminfo(home: home, fileExists: fileExists))
    }

    /// Starts ``look(bundle:environment:home:fileExists:isExecutable:)`` on `work`'s files lane. Shells wait
    /// for it, so a quit never drops it before it runs (`.blockShutdown`: every `finished()` returns).
    static func start(on work: BackgroundWork,
                      look: @escaping @Sendable () -> GhosttyLaunchProbe = { GhosttyLaunchProbe.look() }) -> LaunchRead<GhosttyLaunchProbe> {
        LaunchRead(on: work, shutdown: .blockShutdown, look)
    }
}
