@testable import CmuxNextControl
import Testing

/// The one scrub of an inherited `CMUX_TUI_HOST_NOFILE_SOFT` (pl-cef-tab-nofile review 2): an app
/// started from a shell that carries the open-file launch limit (a cmux-tui owner's environment
/// before it removed it, or a person's export) drops it at launch with every inherited `CMUX*`
/// variable (`LaunchIdentity.stripInheritedEnvironment`), so neither the login-shell capture, a
/// terminal nor the Chief owner sees a stray value; the app names its own launch limit only to the
/// cmux-tui owners it starts (`AppEnvironment.daemonEnvironment`).
struct LaunchLimitStripTests {
    /// cmux-pty `LAUNCH_SOFT_LIMIT_ENV` (`OpenFileLimit.originalSoftLimitKey`).
    static let key = "CMUX_TUI_HOST_NOFILE_SOFT"

    @Test func anInheritedLaunchLimitIsStrippedAtLaunch() {
        let inherited = ["PATH": "/usr/bin:/bin", Self.key: "256"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: inherited, bundledEnvironment: [:]) == [Self.key])
    }
}
