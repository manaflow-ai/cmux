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

    /// An older `cmux` (the classic app's CLI, or a cmux-next CLI from an
    /// older build) that reaches this socket calls a method this app does not
    /// have. The answer keeps `method_not_found` and says the CLI is older than
    /// the app, naming the app's own CLI.
    @Test func anUnknownMethodNamesThisAppsCLI() async throws {
        let cli = "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"
        let identity = ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                       processID: 1, appBundlePath: "/Applications/cmux NEXT.app", appCLIPath: cli)
        let router = ControlRouter(identity: identity, executor: RecordingExecutor(), configuration: .loadTolerant)
        let result = await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: [:]))
        guard case .failure(let error) = result else { Issue.record("expected an error"); return }
        #expect(error.code == "method_not_found")
        #expect(error.message.contains("browser.open_split"))
        #expect(error.message.contains("older than this app"))
        #expect(error.message.contains(cli))
        #expect(error.data?["method"] == "browser.open_split")
        #expect(error.data?["app_cli_path"] == .string(cli))
    }

    @Test func anUnknownMethodWithoutABundledCLIIsPlain() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let result = await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: [:]))
        guard case .failure(let error) = result else { Issue.record("expected an error"); return }
        #expect(error.code == "method_not_found")
        #expect(error.message == "Unknown method browser.open_split")
        #expect(error.data?["app_cli_path"] == nil)
    }

    @Test func identifyReportsNullWithoutABundledCLI() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let result = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [:])).get()
        #expect(result["app_cli_path"] == .null)
    }
}
