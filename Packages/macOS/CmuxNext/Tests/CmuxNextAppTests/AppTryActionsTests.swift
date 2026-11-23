import CmuxNextAppTry
import Testing

/// Run a PR as This App… hands the bundled CLI one `cmux app try` line against this bundle.
struct AppTryActionsTests {
    @Test func runNamesTheTargetAndThisApp() {
        #expect(AppTryActions.runArguments(target: "49745", app: "/Applications/cmux NIGHTLY.app")
            == ["app", "try", "49745", "--app", "/Applications/cmux NIGHTLY.app"])
        #expect(AppTryActions.runArguments(target: "feat/x", app: "/A.app") == ["app", "try", "feat/x", "--app", "/A.app"])
    }

    @Test func aTargetTheCLIWouldReadAsAFlagIsRefused() {
        #expect(AppTryActions.runArguments(target: "--dry-run", app: "/A.app") == nil)
        #expect(AppTryActions.runArguments(target: "-h", app: "/A.app") == nil)
    }
}
