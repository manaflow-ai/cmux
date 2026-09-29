import CmuxNextControl
import Foundation
import Testing

/// A cmux-next launched from a shell inside the user's cmux inherits that
/// cmux's `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_TAG`. None of them
/// may decide which socket cmux-next binds.
@Suite struct LaunchIdentityTests {
    let home = URL(fileURLWithPath: "/Users/u")

    /// What a terminal in the user's release cmux exports.
    let userCmuxShell: [String: String] = [
        "CMUX_SOCKET_PATH": "/Users/u/.local/state/cmux/cmux.sock",
        "CMUX_SOCKET": "/Users/u/.local/state/cmux/cmux.sock",
        "CMUX_BUNDLE_ID": "com.cmuxterm.app",
        "CMUX_TAG": "someone-else",
        "CMUX_WORKSPACE_ID": "ws",
        "CMUX_SURFACE_ID": "sf",
        "CMUX_NEXT_NO_ACTIVATE": "1",
        "HOME": "/Users/u",
        "PATH": "/usr/bin",
    ]

    @Test func ignoresInheritedSocketBundleAndTag() {
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app.debug.nxstab",
            bundledEnvironment: [:],
            processEnvironment: userCmuxShell,
            isDebugBuild: true,
            home: home
        )
        #expect(identity.socketPath == "/tmp/cmux-debug-nxstab.sock")
        #expect(identity.tag == "nxstab")
        #expect(identity.bundleID == "com.cmuxterm.app.debug.nxstab")
    }

    @Test func untaggedDebugIgnoresInheritedTag() {
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app.debug",
            bundledEnvironment: [:],
            processEnvironment: userCmuxShell,
            isDebugBuild: true,
            home: home
        )
        #expect(identity.socketPath == "/tmp/cmux-debug.sock")
        #expect(identity.tag == nil)
    }

    @Test func bundledLaunchEnvironmentNamesTheTag() {
        // scripts/reload.sh writes CMUX_TAG into the bundle's own LSEnvironment.
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app.debug",
            bundledEnvironment: ["CMUX_TAG": "My Tag"],
            processEnvironment: userCmuxShell,
            isDebugBuild: true,
            home: home
        )
        #expect(identity.tag == "my-tag")
        #expect(identity.socketPath == "/tmp/cmux-debug-my-tag.sock")
    }

    @Test func explicitOverrideIsTheOnlyEnvironmentPath() {
        var environment = userCmuxShell
        environment[LaunchIdentity.socketOverrideKey] = "/tmp/next-override.sock"
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app.debug.nxstab",
            bundledEnvironment: [:],
            processEnvironment: environment,
            isDebugBuild: true,
            home: home
        )
        #expect(identity.socketPath == "/tmp/next-override.sock")
    }

    @Test func terminalsGetThisAppsIdentity() {
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app.debug.nxstab",
            bundledEnvironment: [:],
            processEnvironment: userCmuxShell,
            isDebugBuild: true,
            home: home
        )
        #expect(identity.terminalEnvironment == [
            "CMUX_SOCKET_PATH": "/tmp/cmux-debug-nxstab.sock",
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.nxstab",
            "CMUX_TAG": "nxstab",
        ])
    }

    @Test func stripsInheritedCmuxVariablesButKeepsOwnAndLaunchKnobs() {
        let bundled = ["CMUX_DEBUG_LOG": "/tmp/cmux-debug-nxstab.log"]
        var environment = userCmuxShell
        environment["CMUX_DEBUG_LOG"] = "/tmp/cmux-debug-nxstab.log"
        environment["CMUXD_UNIX_PATH"] = "/tmp/other.sock"
        environment["CMUX_TUI_SOCKET"] = "/tmp/other-tui.sock"
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: environment, bundledEnvironment: bundled))
        #expect(stripped == [
            "CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX_BUNDLE_ID", "CMUX_TAG",
            "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUXD_UNIX_PATH", "CMUX_TUI_SOCKET",
        ])
    }

    @Test func releaseBundleUsesTheReleasePath() {
        let identity = LaunchIdentity.resolve(
            bundleID: "com.cmuxterm.app",
            bundledEnvironment: [:],
            processEnvironment: ["CMUX_SOCKET_PATH": "/tmp/x.sock"],
            isDebugBuild: false,
            home: home
        )
        #expect(identity.socketPath == "/Users/u/.local/state/cmux/cmux.sock")
    }
}
