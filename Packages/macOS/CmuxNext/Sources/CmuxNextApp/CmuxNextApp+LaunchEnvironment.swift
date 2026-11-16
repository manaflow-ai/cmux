import CmuxNextCompat
import CmuxNextControl
import CmuxNextProcessEnvironment
import CmuxNextSettings
import CmuxNextTerminal
import Foundation

/// This process's environment writes, in launch order, then the freeze.
/// `CmuxNextApp.main` calls it before any thread starts and before
/// `ghostty_init`: libghostty keeps a copy of `environ` from `ghostty_init`,
/// so a later setenv or unsetenv crashes it (cx-9dh7). Each write site goes
/// through `ProcessEnvironmentGuard.write`, so a write moved after the freeze
/// stops a debug build (check: crash_ratchet.py env_write,
/// env-write-allowlist.json).
extension CmuxNextApp {
    static func prepareLaunchEnvironment(environmentGuard: ProcessEnvironmentGuard = .process) {
        // Cmux variables inherited from a shell inside another cmux, so they
        // cannot pick this app's socket, tag, or daemon session.
        let stripped = LaunchIdentity.stripInheritedEnvironment(environmentGuard: environmentGuard)
        // The names only (never values), so a launch knob lost to another
        // cmux's terminal shows in the app's log.
        if !stripped.isEmpty {
            FileHandle.standardError.write(Data("cmux: ignored inherited \(stripped.joined(separator: " "))\n".utf8))
        }
#if DEBUG
        applyConfigFileArgument(environmentGuard: environmentGuard)
#endif
        applyBuildStatePaths(environmentGuard: environmentGuard)
        GhosttyRuntime.prepareProcessEnvironment(environmentGuard: environmentGuard)
        LaunchMarkSink.dropInheritedDescriptor(environmentGuard: environmentGuard)
        environmentGuard.freeze()
    }

    /// A DEV build's own settings file and the files beside it (``BuildStatePaths``): set for this
    /// process, so the app's own readers (`CmuxConfigFile.defaultURL`, `HostBudgetFile`, `CustomizeFolder`) and
    /// every child that inherits its environment (the daemon, acpmux, the `cmux` CLI in its terminals) use
    /// them. NIGHTLY and every other shared build set nothing. Its config folder is made here, empty: a
    /// fresh DEV build starts from the schema's defaults, never from another build's file.
    static func applyBuildStatePaths(_ paths: BuildStatePaths = .current, environmentGuard: ProcessEnvironmentGuard) {
        let values = paths.launchEnvironment(over: ProcessInfo.processInfo.environment)
        guard !values.isEmpty else { return }
        // concurrency-allow: one mkdir in main before any thread starts, beside the launch's other environment writes.
        try? FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        environmentGuard.write("CmuxNextApp.applyBuildStatePaths") {
            for (key, value) in values { setenv(key, value, 1) }
        }
    }

#if DEBUG
    /// DEBUG: `--config-file PATH` launches on another cmux-next.json, as
    /// `CMUX_NEXT_CONFIG_FILE` does. A capture slot's launcher passes app
    /// arguments but not environment, so this gives a slot its own settings
    /// instead of the mini's shared file. Set before the freeze, so the
    /// daemon and agents started from here read the same file.
    static func applyConfigFileArgument(_ arguments: [String] = ProcessInfo.processInfo.arguments,
                                        environmentGuard: ProcessEnvironmentGuard) {
        guard let flag = arguments.firstIndex(of: "--config-file"), arguments.indices.contains(flag + 1) else { return }
        let path = arguments[flag + 1]
        guard !path.isEmpty, !path.hasPrefix("--") else { return }
        environmentGuard.write("CmuxNextApp.applyConfigFileArgument") {
            setenv(CmuxConfigFile.overrideKey, path, 1)
        }
    }
#endif
}
