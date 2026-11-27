import Foundation
import Testing
@testable import CmuxNextDaemon

/// `exitWithProcess` reaches `server ensure` as `--exit-with-pid`; a launcher
/// that does not set it (the app's) starts an owner that outlives it.
struct DaemonLauncherExitWithTests {
    private let binary = URL(fileURLWithPath: "/nonexistent/cmux-tui")

    @Test func aHarnessOwnerIsTiedToItsProcess() throws {
        let configuration = DaemonLauncher.Configuration(binary: binary, session: "cnd-bd-test", exitWithProcess: 4242)
        let arguments = DaemonLauncher.ensureArguments(configuration)
        let flag = try #require(arguments.firstIndex(of: "--exit-with-pid"))
        #expect(arguments[flag + 1] == "4242")
    }

    @Test func anOwnerWithoutItIsNot() {
        let configuration = DaemonLauncher.Configuration(binary: binary, session: "cmux-app")
        #expect(configuration.exitWithProcess == nil)
        #expect(!DaemonLauncher.ensureArguments(configuration).contains("--exit-with-pid"))
    }
}
