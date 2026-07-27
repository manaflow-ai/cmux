import Testing
@testable import CmuxTerminal

@Suite struct ShortcutKeyPressLifecycleTrackerTests {
    @Test func sameEventFallbackCanClaimUnhandledPress() {
        var tracker = ShortcutKeyPressLifecycleTracker()
        var dispatchCount = 0

        let firstEntryPoint = tracker.shortcutConsumesKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            dispatchCount += 1
            return false
        }
        let fallbackEntryPoint = tracker.shortcutConsumesKeyDown(
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
            #expect(tracker.shortcutConsumesKeyDown(
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

        #expect(!tracker.shortcutConsumesKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            false
        })
        #expect(!tracker.shortcutConsumesKeyDown(
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

        #expect(tracker.shortcutConsumesKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            true
        })
        for _ in 0..<2 {
            #expect(tracker.shortcutConsumesKeyDown(
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

        #expect(!tracker.shortcutConsumesKeyDown(
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

        #expect(tracker.shortcutConsumesKeyDown(
            keyCode: 12,
            eventIdentity: identity(1),
            isRepeat: false
        ) {
            true
        })
        #expect(!tracker.shortcutConsumesKeyDown(
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
            #expect(tracker.shortcutConsumesKeyDown(
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

        #expect(tracker.shortcutConsumesKeyDown(
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
