import Foundation
import Testing
@testable import CmuxNextDaemon

/// p08-startup 033: the keys the app looks up off the main thread (Ghostty's `TERM` and resources folder)
/// reach the daemon's `server ensure` environment over the launch overrides, as they did when `main` probed them.
struct DaemonLauncherResolvedEnvironmentTests {
    @Test func theResolvedKeysGoOverTheLaunchOverrides() async {
        let cache = LoginEnvironmentCache(store: nil, capture: { _ in nil })
        let environment = DaemonLauncher.appEnvironment(
            cache: cache, base: ["HOME": "/home/me", "PATH": "/usr/bin"],
            overrides: ["TERM": "xterm-256color", "CMUX_TAG": "probe"],
            resolved: { ["TERM": "xterm-ghostty", "GHOSTTY_RESOURCES_DIR": "/probe/Resources/ghostty"] })
        let env = await environment()
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["GHOSTTY_RESOURCES_DIR"] == "/probe/Resources/ghostty")
        #expect(env["CMUX_TAG"] == "probe")
    }

    @Test func withoutResolvedKeysTheOverridesStand() async {
        let cache = LoginEnvironmentCache(store: nil, capture: { _ in nil })
        let environment = DaemonLauncher.appEnvironment(cache: cache, base: ["HOME": "/home/me"],
                                                        overrides: ["TERM": "xterm-256color"])
        #expect(await environment()["TERM"] == "xterm-256color")
    }
}
