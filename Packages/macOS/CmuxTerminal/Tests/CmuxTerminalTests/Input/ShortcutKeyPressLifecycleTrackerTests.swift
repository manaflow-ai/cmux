import Testing
@testable import CmuxTerminal

@Suite struct ShortcutKeyPressLifecycleTrackerTests {
    @Test func sameEventFallbackCanClaimUnhandledPress() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var dispatchCount = 0

        let firstEntryPoint = routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            dispatchCount += 1
            return false
        }
        let fallbackEntryPoint = routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            dispatchCount += 1
            return true
        }

        #expect(!firstEntryPoint)
        #expect(fallbackEntryPoint)
        #expect(dispatchCount == 2)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(consumesRelease)
    }

    @Test func shortcutOwnedEventDispatchesAtMostOncePerEntryPointFanout() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var dispatchCount = 0

        for _ in 0..<3 {
            #expect(routeKeyDown(
                tracker: &tracker,
                keyCode: 12,
                eventIdentity: identity(1),
                isRepeat: false
            ) {
                dispatchCount += 1
                return true
            })
        }

        #expect(dispatchCount == 1)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(consumesRelease)
    }

    @Test func responderOwnedPressKeepsRepeatsAndReleaseUnconsumed() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var repeatDispatchCount = 0

        #expect(!routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            false
        })
        #expect(!routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(2),
            isRepeat: true
        ) {
            repeatDispatchCount += 1
            return true
        })

        #expect(repeatDispatchCount == 0)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(!consumesRelease)
    }

    @Test func shortcutOwnedRepeatDispatchesOnceAndRetainsRelease() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var repeatDispatchCount = 0

        #expect(routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            true
        })
        for _ in 0..<2 {
            #expect(routeKeyDown(
                tracker: &tracker,
                keyCode: 12,
                eventIdentity: identity(2),
                isRepeat: true
            ) {
                repeatDispatchCount += 1
                return false
            })
        }

        #expect(repeatDispatchCount == 1)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(consumesRelease)
    }

    @Test func firstObservedRepeatCannotEstablishOwnership() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var dispatchCount = 0

        #expect(!routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(2),
            isRepeat: true
        ) {
            dispatchCount += 1
            return true
        })
        #expect(dispatchCount == 0)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(!consumesRelease)
    }

    @Test func distinctNonRepeatReplacesStaleLifecycle() {
        var tracker = ShortcutKeyPressLifecycleTracker()

        #expect(routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            true
        })
        #expect(!routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(2),
            isRepeat: false
        ) {
            false
        })

        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(!consumesRelease)
    }

    @Test func distinctZeroTimestampEventsDispatchIndependently() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var dispatchCount = 0

        for token in UInt(1)...UInt(2) {
            #expect(routeKeyDown(
                tracker: &tracker,
                keyCode: 12,
                eventIdentity: identity(0, zeroTimestampEventToken: token),
                isRepeat: false
            ) {
                dispatchCount += 1
                return true
            })
        }

        #expect(dispatchCount == 2)
        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(consumesRelease)
    }

    @Test func resetForgetsEveryOwner() {
        var tracker = ShortcutKeyPressLifecycleTracker()

        #expect(routeKeyDown(
            tracker: &tracker,
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            true
        })
        tracker.reset()

        let consumesRelease = tracker.shortcutConsumesKeyUp(keyCode: 12)
        #expect(!consumesRelease)
    }

    @Test func provisionalOwnerConsumesReleaseAndCompletionDoesNotReviveIt() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        let decision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        )
        guard case .dispatch(let dispatch) = decision else {
            Issue.record("A new press should request shortcut dispatch")
            return
        }

        let nestedReleaseConsumed = tracker.shortcutConsumesKeyUp(keyCode: 12)
        let dispatchConsumed = tracker.completeKeyDownDispatch(
            dispatch,
            handled: true
        )
        let laterReleaseConsumed = tracker.shortcutConsumesKeyUp(keyCode: 12)

        #expect(nestedReleaseConsumed)
        #expect(dispatchConsumed)
        #expect(!laterReleaseConsumed)
    }

    @Test func unhandledDispatchRestoresResponderOwnership() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        let decision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        )
        guard case .dispatch(let dispatch) = decision else {
            Issue.record("A new press should request shortcut dispatch")
            return
        }

        let dispatchConsumed = tracker.completeKeyDownDispatch(
            dispatch,
            handled: false
        )
        let repeatDecision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(2),
            isRepeat: true
        )
        let releaseConsumed = tracker.shortcutConsumesKeyUp(keyCode: 12)

        #expect(!dispatchConsumed)
        #expect(repeatDecision == .passThrough)
        #expect(!releaseConsumed)
    }

    @Test func pendingDispatchConsumesRepeatWithoutRedispatching() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        let decision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        )
        guard case .dispatch(let dispatch) = decision else {
            Issue.record("A new press should request shortcut dispatch")
            return
        }

        let repeatDecision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(2),
            isRepeat: true
        )
        let dispatchConsumed = tracker.completeKeyDownDispatch(
            dispatch,
            handled: true
        )
        let releaseConsumed = tracker.shortcutConsumesKeyUp(keyCode: 12)

        #expect(repeatDecision == .consume)
        #expect(dispatchConsumed)
        #expect(releaseConsumed)
    }

    @Test func staleCompletionCannotClaimReplacementAfterReset() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        let firstDecision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        )
        guard case .dispatch(let firstDispatch) = firstDecision else {
            Issue.record("The first press should request shortcut dispatch")
            return
        }

        tracker.reset()

        let replacementDecision = tracker.prepareKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        )
        guard case .dispatch(let replacementDispatch) = replacementDecision else {
            Issue.record("The replacement press should request shortcut dispatch")
            return
        }

        let staleDispatchConsumed = tracker.completeKeyDownDispatch(
            firstDispatch,
            handled: true
        )
        let replacementDispatchConsumed = tracker.completeKeyDownDispatch(
            replacementDispatch,
            handled: false
        )
        let releaseConsumed = tracker.shortcutConsumesKeyUp(keyCode: 12)

        #expect(staleDispatchConsumed)
        #expect(!replacementDispatchConsumed)
        #expect(!releaseConsumed)
    }

    private func routeKeyDown(
        tracker: inout ShortcutKeyPressLifecycleTracker,
        keyCode: UInt16,
        eventIdentity: ShortcutKeyEventIdentity,
        isRepeat: Bool,
        dispatchShortcut: () -> Bool
    ) -> Bool {
        switch tracker.prepareKeyDown(
            keyCode: keyCode,
            eventIdentity: eventIdentity,
            isRepeat: isRepeat
        ) {
        case .passThrough:
            return false
        case .consume:
            return true
        case .dispatch(let dispatch):
            let handled = dispatchShortcut()
            return tracker.completeKeyDownDispatch(
                dispatch,
                handled: handled
            )
        }
    }

    private func identity(
        _ value: UInt64,
        zeroTimestampEventToken: UInt = 0
    ) -> ShortcutKeyEventIdentity {
        ShortcutKeyEventIdentity(
            timestampBitPattern: value,
            windowNumber: 1,
            zeroTimestampEventToken: zeroTimestampEventToken
        )
    }
}
