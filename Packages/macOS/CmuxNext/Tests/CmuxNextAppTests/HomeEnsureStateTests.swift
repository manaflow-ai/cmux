import CmuxNextHomeEngine
import Testing

/// "Home not ensured yet", the launch rule's input (cmux-window-rules `launch::fresh_landing`): while it holds, the
/// launch makes nothing. It ends when an `ensure_home` answers or the daemon can no longer ensure Home; no timer.
@MainActor
struct HomeEnsureStateTests {
    private func notEnsuredYet(_ state: HomeEnsureState, canEnsure: Bool = true) -> Bool {
        state.freshFacts(emptyTree: true, classicHome: false, homeEnsured: false, canEnsure: canEnsure).0.homeNotEnsuredYet
    }

    /// Home starts after the first frame: no `ensure_home` is in flight yet, and the launch still waits.
    @Test func aLaunchThatEnsuresHomeWaitsBeforeAnyEnsureHome() {
        let state = HomeEnsureState()
        state.ensuresAtLaunch = true
        #expect(notEnsuredYet(state))
        #expect(state.freshFacts(emptyTree: true, classicHome: false, homeEnsured: false, canEnsure: true).ensureInFlight == false)
        let generation = state.begin()
        #expect(notEnsuredYet(state))
        state.settle(generation)
        #expect(!notEnsuredYet(state))
    }

    /// A daemon that cannot ensure Home (disconnected, no `workspace-kind-v1`) ends the wait.
    @Test func aDaemonThatCannotEnsureHomeEndsTheWait() {
        let state = HomeEnsureState()
        state.ensuresAtLaunch = true
        #expect(!notEnsuredYet(state, canEnsure: false))
    }

    /// Where nothing starts Home, only an `ensure_home` in flight waits; an older one's answer keeps a newer in flight.
    @Test func onlyTheLatestEnsureHomeEndsTheWait() {
        let state = HomeEnsureState()
        #expect(!notEnsuredYet(state))
        let first = state.begin()
        let second = state.begin()
        state.settle(first)
        #expect(notEnsuredYet(state))
        state.settle(second)
        #expect(!notEnsuredYet(state))
    }
}
