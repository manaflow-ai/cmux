import Testing
@testable import CmuxTerminal

@Suite struct TerminalKeyInputLifecycleTrackerTests {
    @Test func consumedRepeatKeepsTerminalReleaseOwnership() {
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
        #expect(repeatActions.isEmpty)
        #expect(release.forwardsPhysicalKey)
    }

    @Test func terminalOwnedRepeatUsesCurrentSemanticMeaning() {
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

        #expect(repeatActions == [.sendKey(text: "q", composing: false)])
    }

    @Test func terminalOwnedRepeatDoesNotDuplicateNewCommittedPreeditText() {
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

        #expect(repeatActions == [.sendCommittedText("한")])
    }

    @Test func composingPressOwnsItsMatchingRelease() {
        var tracker = TerminalKeyInputLifecycleTracker()
        let composingPlan = TerminalKeyInputPlan(actions: [
            .sendKey(text: "ᄒ", composing: true),
        ])

        let pressActions = tracker.actions(
            for: composingPlan,
            keyCode: 4,
            isRepeat: false
        )
        let release = tracker.release(forKeyUp: 4)

        #expect(pressActions == [.sendKey(text: "ᄒ", composing: true)])
        #expect(release.forwardsPhysicalKey)
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

    @Test func appKitOwnedRepeatPreservesDirectAppKitCommitWithoutPhysicalOwnership() {
        var tracker = TerminalKeyInputLifecycleTracker()
        let planner = TerminalKeyInputPlanner()
        _ = tracker.actions(
            for: consumedPlan(),
            keyCode: 0,
            isRepeat: false
        )

        let repeatPlan = planner.plan(for: TerminalKeyInputSnapshot(
            hadMarkedText: false,
            hasMarkedText: false,
            textInputConsumed: true,
            textInputCommandPerformed: false,
            committedText: ["é"],
            event: TerminalKeyInputEvent(
                translatedText: nil,
                rawText: "e"
            )
        ))
        let repeatActions = tracker.actions(
            for: repeatPlan,
            keyCode: 0,
            isRepeat: true
        )
        let release = tracker.release(forKeyUp: 0)

        #expect(repeatActions == [.sendCommittedText("é")])
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

    @Test func repeatKeepsStableBindingIdentityAcrossLayoutChanges() {
        var tracker = TerminalKeyInputLifecycleTracker()
        let initialIdentity = TerminalKeyInputPhysicalIdentity(
            unshiftedCodepoint: 0x63,
            consumedModifierMask: 0x04
        )
        let repeatIdentity = TerminalKeyInputPhysicalIdentity(
            unshiftedCodepoint: 0x0441,
            consumedModifierMask: 0
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
        let resolvedRepeatIdentity = tracker.physicalIdentity(
            forKeyDown: 8,
            resolvedIdentity: repeatIdentity,
            isRepeat: true
        )
        let release = tracker.release(forKeyUp: 8)

        #expect(pressIdentity == initialIdentity)
        #expect(
            resolvedRepeatIdentity == initialIdentity,
            "Text and consumed modifiers may change on repeat, but Ghostty's binding identity must stay paired with key-up"
        )
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
