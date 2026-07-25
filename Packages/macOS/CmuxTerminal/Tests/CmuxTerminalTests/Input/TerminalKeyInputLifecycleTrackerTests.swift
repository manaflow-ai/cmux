import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputLifecycleTrackerTests {
    @Test func consumedRepeatCannotStealReleaseFromForwardedPress() {
        var tracker = TerminalKeyInputLifecycleTracker()

        let pressActions = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 0,
            isRepeat: false
        )
        let repeatActions = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: true
        )
        let forwardsRelease = tracker.shouldForwardKeyUp(keyCode: 0)

        #expect(pressActions == [.sendKey(text: "a", composing: false)])
        #expect(repeatActions.isEmpty)
        #expect(forwardsRelease)
    }

    @Test func forwardedRepeatCannotCreateLifecycleForConsumedPress() {
        var tracker = TerminalKeyInputLifecycleTracker()

        let pressActions = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: false
        )
        let repeatActions = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 0,
            isRepeat: true
        )
        let forwardsRelease = tracker.shouldForwardKeyUp(keyCode: 0)

        #expect(pressActions.isEmpty)
        #expect(repeatActions.isEmpty)
        #expect(!forwardsRelease)
    }

    @Test func appKitOwnedRepeatPreservesCommittedPreeditText() {
        var tracker = TerminalKeyInputLifecycleTracker()
        _ = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: false
        )

        let repeatActions = tracker.actions(
            for: TerminalKeyInputPlan(actions: [
                .sendCommittedText("한"),
                .sendKey(text: nil, composing: false),
            ]),
            keyCode: 0,
            isRepeat: true
        )
        let forwardsRelease = tracker.shouldForwardKeyUp(keyCode: 0)

        #expect(repeatActions == [.sendCommittedText("한")])
        #expect(!forwardsRelease)
    }

    @Test func firstObservedRepeatEstablishesReleaseOwnership() {
        var tracker = TerminalKeyInputLifecycleTracker()

        let consumedRepeatActions = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: true
        )
        let forwardsConsumedRelease = tracker.shouldForwardKeyUp(keyCode: 0)

        let forwardedRepeatActions = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 1,
            isRepeat: true
        )
        let forwardsTerminalRelease = tracker.shouldForwardKeyUp(keyCode: 1)

        #expect(consumedRepeatActions.isEmpty)
        #expect(!forwardsConsumedRelease)
        #expect(forwardedRepeatActions == [.sendKey(text: "a", composing: false)])
        #expect(forwardsTerminalRelease)
    }

    @Test func resetForgetsExistingOwners() {
        var tracker = TerminalKeyInputLifecycleTracker()
        _ = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: false
        )

        tracker.reset()
        let forwardsRelease = tracker.shouldForwardKeyUp(keyCode: 0)

        #expect(forwardsRelease)
    }

    private func consumedPlan() -> TerminalKeyInputPlan {
        TerminalKeyInputPlan(actions: [])
    }

    private func physicalPlan(text: String) -> TerminalKeyInputPlan {
        TerminalKeyInputPlan(actions: [.sendKey(text: text, composing: false)])
    }
}
