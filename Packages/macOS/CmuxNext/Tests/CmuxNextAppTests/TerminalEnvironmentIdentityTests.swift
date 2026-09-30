import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// The environment the app hands its daemon and every local terminal
/// carries Ghostty's terminal identity next to the launch identity.
struct TerminalEnvironmentIdentityTests {
    @Test func carriesGhosttysTerminalIdentityAndTheLaunchIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-ghostty-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("terminfo/78"), withIntermediateDirectories: true)
        try Data("entry".utf8).write(to: root.appendingPathComponent("terminfo/78/xterm-ghostty"))

        let launch = LaunchIdentity(bundleID: "com.cmuxterm.app.next.debug.t1", tag: "t1", socketPath: "/tmp/t1.sock")
        // The test bundle has no bundled resources, so an inherited
        // GHOSTTY_RESOURCES_DIR is the first candidate with themes.
        let env = AppEnvironment.terminalEnvironment(launch: launch, environment: ["GHOSTTY_RESOURCES_DIR": resources.path])

        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TERMINFO"] == root.appendingPathComponent("terminfo").path)
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERM_PROGRAM_VERSION"]?.isEmpty == false)
        #expect(env["GHOSTTY_RESOURCES_DIR"] == resources.path)
        for (key, value) in launch.terminalEnvironment { #expect(env[key] == value, "\(key)") }
    }
}
