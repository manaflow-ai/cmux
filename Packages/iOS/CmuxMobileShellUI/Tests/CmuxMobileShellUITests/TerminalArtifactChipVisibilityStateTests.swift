import Testing
@testable import CmuxMobileShellUI

@Suite("Terminal artifact chip visibility")
struct TerminalArtifactChipVisibilityStateTests {
    @Test("positive counts mount immediately and dedupe repeats")
    func mounts() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 3, enabled: true) == .none)
        #expect(state.update(count: 4, enabled: true) == .mount(count: 4))
    }

    @Test("a zero count schedules a hide instead of unmounting")
    func zeroSchedulesHide() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 0, enabled: true) == .scheduleHide)
        #expect(state.update(count: 0, enabled: true) == .none)
    }

    @Test("a positive count during the hide grace remounts, even at the same value")
    func positiveCountCancelsPendingHide() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 0, enabled: true) == .scheduleHide)
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 0, enabled: true) == .scheduleHide)
    }

    @Test("zero counts while unmounted do nothing")
    func zeroWhileUnmounted() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 0, enabled: true) == .none)
        #expect(state.update(count: 0, enabled: false) == .none)
    }

    @Test("disabling hides immediately from mounted and hide-pending states")
    func disableHidesNow() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 3, enabled: false) == .hideNow)
        #expect(state.update(count: 3, enabled: false) == .none)

        var pending = TerminalArtifactChipVisibilityState()
        #expect(pending.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(pending.update(count: 0, enabled: true) == .scheduleHide)
        #expect(pending.update(count: 0, enabled: false) == .hideNow)
    }

    @Test("a completed hide unmounts, so the next positive count mounts again")
    func hideCompletionUnmounts() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        #expect(state.update(count: 0, enabled: true) == .scheduleHide)
        state.hideCompleted()
        #expect(state.update(count: 0, enabled: true) == .none)
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
    }

    @Test("reset returns to unmounted without a transition")
    func resetUnmounts() {
        var state = TerminalArtifactChipVisibilityState()
        #expect(state.update(count: 3, enabled: true) == .mount(count: 3))
        state.reset()
        #expect(state.update(count: 0, enabled: true) == .none)
        #expect(state.update(count: 2, enabled: true) == .mount(count: 2))
    }
}
