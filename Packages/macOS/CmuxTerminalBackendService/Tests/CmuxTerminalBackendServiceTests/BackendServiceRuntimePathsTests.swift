import CmuxTerminalBackendService
import Foundation
import Testing

@Suite("Persistent backend runtime paths")
struct BackendServiceRuntimePathsTests {
    @Test("service paths match the environment-independent cmux-tui layout")
    func serviceLayout() throws {
        let descriptor = try #require(
            BackendServiceDescriptor(bundleIdentifier: "com.cmuxterm.app.debug.renderer-a")
        )
        let paths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: 501,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        #expect(
            paths.socketURL.path
                == "/tmp/cmux-tui-501/cmux-z3ogyutjsmgrkezxttum65pgym.sock"
        )
        #expect(
            paths.stateDirectoryURL.path
                == "/Users/tester/Library/Application Support/cmux-tui/state"
        )
        #expect(
            paths.serviceInstallationRootURL.path
                == "/Users/tester/Library/Application Support/cmux/terminal-backend/com.cmuxterm.app.debug.renderer-a"
        )
        #expect(
            paths.launchAgentPropertyListURL.path
                == "/Users/tester/Library/LaunchAgents/com.cmuxterm.app.debug.renderer-a.terminal-backend.plist"
        )
    }
}
