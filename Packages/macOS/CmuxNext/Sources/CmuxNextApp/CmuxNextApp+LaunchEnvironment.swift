import CmuxNextControl
import CmuxNextLaunch
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
///
/// Its Ghostty resources lookup is the one disk probe `main` makes before
/// `NSApplication.run`: the write it feeds must come before any thread exists,
/// so no launch lane can do it (Chrome checks its user data directory on the
/// main thread before its threads start the same way: `InitializeUserDataDir`
/// in chrome/app/chrome_main_delegate.cc). The launch reuses its result rather
/// than probing again.
extension CmuxNextApp {
    /// - Returns: The Ghostty resources directory (`GhosttyRuntime.resourcesDirectory`), nil when none has themes.
    @discardableResult
    static func prepareLaunchEnvironment(environmentGuard: ProcessEnvironmentGuard = .process) -> String? {
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
        let ghosttyResources = GhosttyRuntime.prepareProcessEnvironment(environmentGuard: environmentGuard)
        LaunchMarkSink.dropInheritedDescriptor(environmentGuard: environmentGuard)
        environmentGuard.freeze()
        return ghosttyResources
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
