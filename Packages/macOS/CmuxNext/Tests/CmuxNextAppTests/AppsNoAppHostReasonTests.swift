import CmuxNextApps
import Testing
@testable import CmuxNextApp

/// A connected daemon without `apps-v1` has no app host beside it (cmux-tui advertises the
/// capability only when the `cmux-app-host` binary exists). Updating or restarting does not
/// change that, so the Apps page banner and an app action's refusal say apps cannot run in this
/// build, not "Needs a newer cmux" or "out of date" (Lawrence, 2026-11-12: "get rid of
/// “Needs a newer cmux”").
@Suite struct AppsNoAppHostReasonTests {
    @Test func aDaemonWithoutAppsV1SaysAppsCannotRunInThisBuild() throws {
        let reason = try #require(DaemonAppsTransport.unavailableReason(capabilities: ["identify-v1"]))
        #expect(reason.text == "Apps can’t run in this build of cmux")
        #expect(AppStoreHandlers.unavailable(reason).message == reason.text)
    }
}
