import CmuxNextHomeEngine
import Observation
import Testing

/// A first launch with no workspace of the person's own lands on Home, the Chief's workspace,
/// instead of making an empty New Tab workspace (Leo 2026-10-19: the Chief as the front door).
/// Classic Home keeps the New Tab workspace.
struct FirstWorkspaceLandingTests {
    @Test func homeIsTheFrontDoorByDefault() {
        #expect(FirstWorkspaceLanding(classic: false).home("ws_home") == "ws_home")
    }

    @Test func classicHomeMakesANewTabWorkspace() {
        #expect(FirstWorkspaceLanding(classic: true).home("ws_home") == nil)
    }

    @Test func noHomeWorkspaceYetMakesANewTabWorkspace() {
        #expect(FirstWorkspaceLanding(classic: false).home(nil) == nil)
    }

    /// A fresh store can answer `ensure_home` before its snapshot lists the workspace: the launch
    /// waits for the listing instead of falling back to a New Tab workspace by timing.
    @MainActor @Test func aHomeListedAfterEnsureHomeStillLands() async {
        let store = ListedHome()
        // task-owner: the test; lists Home once the wait has started
        Task { @MainActor in store.id = "ws_home" }
        let home = await FirstWorkspaceLanding(classic: false, deadline: .seconds(30)).home(ensured: true) { store.id }
        #expect(home == "ws_home")
    }

    @MainActor @Test func aHomeNeverListedFallsBackAfterTheDeadline() async {
        let store = ListedHome()
        let home = await FirstWorkspaceLanding(classic: false, deadline: .milliseconds(50)).home(ensured: true) { store.id }
        #expect(home == nil)
    }

    @MainActor @Test func noEnsureHomeOrClassicHomeDoesNotWait() async {
        let store = ListedHome()
        store.id = "ws_home"
        let notEnsured = await FirstWorkspaceLanding(classic: false, deadline: .seconds(30)).home(ensured: false) { store.id }
        let classic = await FirstWorkspaceLanding(classic: true, deadline: .seconds(30)).home(ensured: true) { store.id }
        #expect(notEnsured == nil)
        #expect(classic == nil)
    }
}

/// The store's listing of the Home workspace, as `HomeService.homeWorkspace` reads it.
@MainActor @Observable
private final class ListedHome {
    var id: String?
}
