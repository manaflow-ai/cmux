import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputLifecycleTrackerTests {
    @Test func consumedRepeatRetainsForwardedPressLifecycle() {
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
        let release = tracker.release(forKeyUp: 0)

        #expect(pressActions == [.sendKey(text: "a", composing: false)])
        #expect(repeatActions == [.sendKey(text: "a", composing: false)])
        #expect(release.forwardsPhysicalKey)
    }

    @Test func terminalOwnedRepeatRetainsInitialPhysicalMeaning() {
        var tracker = TerminalKeyInputLifecycleTracker()

        _ = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 0,
            isRepeat: false
        )
        let repeatActions = tracker.actions(
            for: physicalPlan(text: "q"),
            keyCode: 0,
            isRepeat: true
        )

        #expect(repeatActions == [.sendKey(text: "a", composing: false)])
    }

    @Test func terminalOwnedRepeatPreservesNewCommittedPreeditText() {
        var tracker = TerminalKeyInputLifecycleTracker()

        _ = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 0,
            isRepeat: false
        )
        let repeatActions = tracker.actions(
            for: TerminalKeyInputPlan(actions: [
                .sendCommittedText("한"),
            ]),
            keyCode: 0,
            isRepeat: true
        )

        #expect(repeatActions == [
            .sendCommittedText("한"),
            .sendKey(text: "a", composing: false),
        ])
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
        let release = tracker.release(forKeyUp: 0)

        #expect(pressActions.isEmpty)
        #expect(repeatActions.isEmpty)
        #expect(!release.forwardsPhysicalKey)
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
        let release = tracker.release(forKeyUp: 0)

        #expect(repeatActions == [.sendCommittedText("한")])
        #expect(!release.forwardsPhysicalKey)
    }

    @Test func firstObservedRepeatEstablishesReleaseOwnership() {
        var tracker = TerminalKeyInputLifecycleTracker()

        let consumedRepeatActions = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: true
        )
        let consumedRelease = tracker.release(forKeyUp: 0)

        let forwardedRepeatActions = tracker.actions(
            for: physicalPlan(text: "a"),
            keyCode: 1,
            isRepeat: true
        )
        let terminalRelease = tracker.release(forKeyUp: 1)

        #expect(consumedRepeatActions.isEmpty)
        #expect(!consumedRelease.forwardsPhysicalKey)
        #expect(forwardedRepeatActions == [.sendKey(text: "a", composing: false)])
        #expect(terminalRelease.forwardsPhysicalKey)
    }

    @Test func resetForgetsExistingOwners() {
        var tracker = TerminalKeyInputLifecycleTracker()
        _ = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: false
        )

        tracker.reset()
        let release = tracker.release(forKeyUp: 0)

        #expect(release.forwardsPhysicalKey)
    }

    @Test func physicalIdentitySurvivesRepeatAndRelease() {
        var tracker = TerminalKeyInputLifecycleTracker()
        let initialIdentity = TerminalKeyInputPhysicalIdentity(
            unshiftedCodepoint: 0x63,
            consumedModifierMask: 0x04
        )
        _ = tracker.actions(
            for: physicalPlan(text: "c"),
            keyCode: 8,
            isRepeat: false
        )

        let pressIdentity = tracker.physicalIdentity(
            forKeyDown: 8,
            resolvedIdentity: initialIdentity,
            isRepeat: false
        )
        let repeatIdentity = tracker.physicalIdentity(
            forKeyDown: 8,
            resolvedIdentity: TerminalKeyInputPhysicalIdentity(
                unshiftedCodepoint: 0x0441,
                consumedModifierMask: 0
            ),
            isRepeat: true
        )
        let release = tracker.release(forKeyUp: 8)

        #expect(pressIdentity == initialIdentity)
        #expect(repeatIdentity == initialIdentity)
        #expect(release == TerminalKeyInputRelease(
            forwardsPhysicalKey: true,
            physicalIdentity: initialIdentity
        ))
    }

    @Test func resetClearsPhysicalIdentity() {
        var tracker = TerminalKeyInputLifecycleTracker()
        _ = tracker.actions(
            for: physicalPlan(text: "c"),
            keyCode: 8,
            isRepeat: false
        )
        _ = tracker.physicalIdentity(
            forKeyDown: 8,
            resolvedIdentity: TerminalKeyInputPhysicalIdentity(
                unshiftedCodepoint: 0x63,
                consumedModifierMask: 0x04
            ),
            isRepeat: false
        )

        tracker.reset()
        let release = tracker.release(forKeyUp: 8)

        #expect(release == TerminalKeyInputRelease(
            forwardsPhysicalKey: true,
            physicalIdentity: nil
        ))
    }

    private func consumedPlan() -> TerminalKeyInputPlan {
        TerminalKeyInputPlan(actions: [])
    }

    private func physicalPlan(text: String) -> TerminalKeyInputPlan {
        TerminalKeyInputPlan(actions: [.sendKey(text: text, composing: false)])
    }
}
