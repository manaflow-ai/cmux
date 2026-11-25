import CmuxNextHomeEngine
import Observation
import Testing

/// Once the launch rule (cmux-window-rules `launch::fresh_landing`) answered Home, the first launch waits for the
/// store to list the Home workspace `ensure_home` named. Home or a New Tab workspace (classic Home, no Home
/// workspace) is the rule's decision, tested in Rust (`launch_tests.rs`).
struct FirstWorkspaceLandingTests {
    @MainActor @Test func aListedHomeLandsAtOnce() async {
        let store = ListedHome()
        store.id = "ws_home"
        #expect(await FirstWorkspaceLanding(deadline: .seconds(30)).home { store.id } == "ws_home")
    }

    /// A fresh store can answer `ensure_home` before its snapshot lists the workspace: the launch
    /// waits for the listing instead of falling back to a New Tab workspace by timing.
    @MainActor @Test func aHomeListedAfterEnsureHomeStillLands() async {
        let store = ListedHome()
        // task-owner: the test; lists Home once the wait has started
        Task { @MainActor in store.id = "ws_home" }
        let home = await FirstWorkspaceLanding(deadline: .seconds(30)).home { store.id }
        #expect(home == "ws_home")
    }

    @MainActor @Test func aHomeNeverListedFallsBackAfterTheDeadline() async {
        let store = ListedHome()
        let home = await FirstWorkspaceLanding(deadline: .milliseconds(50)).home { store.id }
        #expect(home == nil)
    }
}

/// The store's listing of the Home workspace, as `HomeService.homeWorkspace` reads it.
@MainActor @Observable
private final class ListedHome {
    var id: String?
}
