@testable import CmuxNextControl
import Testing

/// `system.identify` names this app's bundle and bundled CLI with the same
/// keys as the old app (`app_bundle_path`, `app_cli_path`), so a `cmux` CLI
/// that reached the wrong app's socket can name the CLI that matches it.
@Suite struct IdentifyAppPathsTests {
    @Test func identifyReportsBundleAndCLIPaths() async throws {
        let identity = ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                       processID: 1, appBundlePath: "/Applications/cmux NEXT.app",
                                       appCLIPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
        let router = ControlRouter(identity: identity, executor: RecordingExecutor(), configuration: .loadTolerant)
        let result = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [:])).get()
        #expect(result["app"] == "cmux-next")
        #expect(result["app_bundle_path"] == "/Applications/cmux NEXT.app")
        #expect(result["app_cli_path"] == "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
    }

    @Test func identifyReportsNullWithoutABundledCLI() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let result = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [:])).get()
        #expect(result["app_cli_path"] == .null)
    }
}
