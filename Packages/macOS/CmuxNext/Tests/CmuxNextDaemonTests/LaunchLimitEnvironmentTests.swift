import CmuxNextCompat
@testable import CmuxNextDaemon
import Testing

/// `CMUX_TUI_HOST_NOFILE_SOFT` (the open-file limit cmux was launched with) is for cmux-tui
/// owners only (pl-cef-tab-nofile review 1). An inherited copy never reaches this layer: the app
/// removes it with every inherited `CMUX*` variable at launch (`LaunchIdentity.inheritedKeys`,
/// CmuxNextControlTests); only the app's `daemonEnvironment` names it, to the owners it starts.
struct LaunchLimitEnvironmentTests {
    static let key = OpenFileLimit.originalSoftLimitKey

    /// The Chief owner keeps the launch limit the app gives it (its brains and their tool shells
    /// get it back) and still drops every build identity.
    @Test func theChiefOwnerKeepsTheLaunchLimit() {
        let base = ["HOME": "/Users/someone", Self.key: "256", "CMUX_SOCKET_PATH": "/tmp/cmux.sock"]
        #expect(DaemonLauncher.chiefEnvironment(base) == ["HOME": "/Users/someone", Self.key: "256"])
    }
}
