import CmuxNextControl
import CmuxNextProcessEnvironment
import CmuxNextTerminal

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
        LaunchIdentity.stripInheritedEnvironment(environmentGuard: environmentGuard)
        GhosttyRuntime.prepareProcessEnvironment(environmentGuard: environmentGuard)
        LaunchMarkSink.dropInheritedDescriptor(environmentGuard: environmentGuard)
        environmentGuard.freeze()
    }
}
