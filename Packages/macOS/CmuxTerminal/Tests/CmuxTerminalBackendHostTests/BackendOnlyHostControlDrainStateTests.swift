@testable import CmuxTerminalBackendHost
import Testing

@Suite("Backend-only host control drain state")
struct BackendOnlyHostControlDrainStateTests {
    @Test("a burst keeps one drain and only the newest combined state")
    func burstCoalescesToNewestCombinedState() throws {
        var state = BackendOnlyHostControlDrainState()

        let visibilityStartedDrain = state.setVisibility(true)
        #expect(visibilityStartedDrain)
        let focusStartedDrain = state.setFocus(true)
        #expect(!focusStartedDrain)
        let hideStartedDrain = state.setVisibility(false)
        #expect(!hideStartedDrain)
        let blurStartedDrain = state.setFocus(false)
        #expect(!blurStartedDrain)
        let reshowStartedDrain = state.setVisibility(true)
        #expect(!reshowStartedDrain)

        let target = try #require(state.latestTarget())
        #expect(target.values == .init(visible: true, focused: false))
        #expect(state.isCurrent(target))
        let targetNeedsAnotherDrain = state.complete(target)
        #expect(!targetNeedsAnotherDrain)
        #expect(state.latestTarget() == nil)
    }

    @Test("a stale completion preserves the newer desired state")
    func staleCompletionKeepsNewerStatePending() throws {
        var state = BackendOnlyHostControlDrainState()

        let visibilityStartedDrain = state.setVisibility(true)
        #expect(visibilityStartedDrain)
        let stale = try #require(state.latestTarget())
        let focusStartedDrain = state.setFocus(true)
        #expect(!focusStartedDrain)

        #expect(!state.isCurrent(stale))
        let staleTargetNeedsAnotherDrain = state.complete(stale)
        #expect(staleTargetNeedsAnotherDrain)

        let latest = try #require(state.latestTarget())
        #expect(latest.values == .init(visible: true, focused: true))
        #expect(state.isCurrent(latest))
        let latestTargetNeedsAnotherDrain = state.complete(latest)
        #expect(!latestTargetNeedsAnotherDrain)
        #expect(state.latestTarget() == nil)
    }

    @Test("repeating the desired state does not publish more work")
    func duplicateValuesDoNotPublishWork() throws {
        var state = BackendOnlyHostControlDrainState()

        let duplicateVisibilityStartedDrain = state.setVisibility(false)
        #expect(!duplicateVisibilityStartedDrain)
        let duplicateFocusStartedDrain = state.setFocus(false)
        #expect(!duplicateFocusStartedDrain)
        #expect(state.latestTarget() == nil)

        let focusStartedDrain = state.setFocus(true)
        #expect(focusStartedDrain)
        let duplicateFocusedStartedDrain = state.setFocus(true)
        #expect(!duplicateFocusedStartedDrain)
        let target = try #require(state.latestTarget())
        let targetNeedsAnotherDrain = state.complete(target)
        #expect(!targetNeedsAnotherDrain)
        let appliedFocusStartedDrain = state.setFocus(true)
        #expect(!appliedFocusStartedDrain)
        #expect(state.latestTarget() == nil)
    }
}
