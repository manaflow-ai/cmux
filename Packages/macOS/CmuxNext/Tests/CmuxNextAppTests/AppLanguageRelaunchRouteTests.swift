import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextUpdater
import Testing

/// Settings > General > Language's relaunch row: `cmux.settings.language.relaunch` relaunches only
/// on the person's own click in the page.
@MainActor
struct AppLanguageRelaunchRouteTests {
    @Test func theRelaunchRowNeedsAClick() async throws {
        var relaunches = 0
        let route = AppLanguageRelaunchRoute { relaunches += 1 }
        let op = AppLanguageRelaunchRoute.prefix + "relaunch"
        await #expect(throws: PageError.self) {
            _ = try await route.call(op, params: .object([:]), context: PageCallContext(page: "cmux.settings"))
        }
        #expect(relaunches == 0)
        _ = try await route.call(op, params: .object([:]), context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(relaunches == 1)
    }

    @Test func anotherOpIsUnknown() async {
        let route = AppLanguageRelaunchRoute { Issue.record("relaunched") }
        await #expect(throws: PageError.self) {
            _ = try await route.call(AppLanguageRelaunchRoute.prefix + "other", params: .object([:]),
                                     context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
    }
}
