@testable import CmuxTerminalBackendHost
import Testing

@Suite("Backend-only host control drain state")
struct BackendOnlyHostControlDrainStateTests {
    @Test("a burst keeps one drain and only the newest combined state")
    func burstCoalescesToNewestCombinedState() throws {
        var state = BackendOnlyHostControlDrainState()

        #expect(state.setVisibility(true))
        #expect(!state.setFocus(true))
        #expect(!state.setVisibility(false))
        #expect(!state.setFocus(false))
        #expect(!state.setVisibility(true))

        let target = try #require(state.latestTarget())
        #expect(target.values == .init(visible: true, focused: false))
        #expect(state.isCurrent(target))
        #expect(!state.complete(target))
        #expect(state.latestTarget() == nil)
    }

    @Test("a stale completion preserves the newer desired state")
    func staleCompletionKeepsNewerStatePending() throws {
        var state = BackendOnlyHostControlDrainState()

        #expect(state.setVisibility(true))
        let stale = try #require(state.latestTarget())
        #expect(!state.setFocus(true))

        #expect(!state.isCurrent(stale))
        #expect(state.complete(stale))

        let latest = try #require(state.latestTarget())
        #expect(latest.values == .init(visible: true, focused: true))
        #expect(state.isCurrent(latest))
        #expect(!state.complete(latest))
        #expect(state.latestTarget() == nil)
    }

    @Test("repeating the desired state does not publish more work")
    func duplicateValuesDoNotPublishWork() throws {
        var state = BackendOnlyHostControlDrainState()

        #expect(!state.setVisibility(false))
        #expect(!state.setFocus(false))
        #expect(state.latestTarget() == nil)

        #expect(state.setFocus(true))
        #expect(!state.setFocus(true))
        let target = try #require(state.latestTarget())
        #expect(!state.complete(target))
        #expect(!state.setFocus(true))
        #expect(state.latestTarget() == nil)
    }
}
