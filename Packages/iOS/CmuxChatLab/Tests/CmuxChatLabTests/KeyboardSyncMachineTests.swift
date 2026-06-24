import CoreGraphics
import Testing

@testable import CmuxChatLab

/// Behavior of the keyboard/scroll sync state machine (idle / scrolling /
/// dismissing / releasing). The headline guarantee, and the bug it fixes: a
/// keyboard-open scroll stays in `scrolling` and writes the inset ZERO times.
/// Only an actual interactive dismiss (the composer moving) reaches `dismissing`
/// and takes the inset.
struct KeyboardSyncMachineTests {
    /// A machine already in a keyboard-open drag (observer running), positioned
    /// at composer-top 400.
    private func observing(threshold: CGFloat = 4) -> KeyboardSyncMachine {
        var m = KeyboardSyncMachine(engageThreshold: threshold)
        _ = m.handle(.beganDragging(keyboardOpen: true))
        _ = m.handle(.linkTick(composerTop: 400)) // seeds the engage baseline
        return m
    }

    // MARK: Entry

    @Test func dragWithKeyboardOpenStartsObserver() {
        var m = KeyboardSyncMachine()
        let effects = m.handle(.beganDragging(keyboardOpen: true))
        #expect(m.state == .scrolling)
        #expect(effects == [.startLink])
        #expect(!m.ownsInsetViaLink) // observing, not writing
    }

    @Test func dragWithKeyboardClosedStartsNoLink() {
        var m = KeyboardSyncMachine()
        let effects = m.handle(.beganDragging(keyboardOpen: false))
        #expect(m.state == .scrolling)
        #expect(effects.isEmpty) // nothing to dismiss -> no link at all
    }

    // MARK: The headline: keyboard-open scroll never writes the inset

    @Test func keyboardOpenScrollNeverWritesInset() {
        var m = observing()
        // Composer stays put (keyboard not moving) across many frames of scroll.
        for _ in 0..<30 {
            #expect(m.handle(.linkTick(composerTop: 400)).isEmpty)
        }
        #expect(m.state == .scrolling)
        // A little jitter under the engage threshold still doesn't write.
        #expect(m.handle(.linkTick(composerTop: 402)).isEmpty)
        #expect(m.handle(.linkTick(composerTop: 398)).isEmpty)
        #expect(m.state == .scrolling)
    }

    @Test func keyboardOpenScrollEndsCleanlyWithStopLink() {
        var m = observing()
        _ = m.handle(.linkTick(composerTop: 401))
        let effects = m.handle(.endedDragging)
        #expect(m.state == .idle)
        #expect(effects == [.stopLink]) // observer torn down, inset never touched
    }

    @Test func keyboardClosedScrollEndsWithNoEffects() {
        var m = KeyboardSyncMachine()
        _ = m.handle(.beganDragging(keyboardOpen: false))
        #expect(m.handle(.endedDragging) == []) // no link was ever started
        #expect(m.state == .idle)
    }

    // MARK: Engaging the dismiss

    @Test func composerMovingPastThresholdEngagesDismissing() {
        var m = observing(threshold: 4)
        #expect(m.handle(.linkTick(composerTop: 402)).isEmpty)        // under threshold
        let engage = m.handle(.linkTick(composerTop: 410))            // moved 10 > 4
        #expect(m.state == .dismissing)
        #expect(engage == [.applyPerFrame(composerTop: 410)])
        #expect(m.ownsInsetViaLink)
    }

    @Test func dismissingWritesEveryFrameAndNeverSettlesWhileDown() {
        var m = observing()
        _ = m.handle(.linkTick(composerTop: 460)) // engage
        #expect(m.state == .dismissing)
        for top in stride(from: CGFloat(500), through: 620, by: 40) {
            #expect(m.handle(.linkTick(composerTop: top)) == [.applyPerFrame(composerTop: top)])
        }
        // Even if the composer pauses under a held finger, dismissing never settles.
        for _ in 0..<5 {
            #expect(m.handle(.linkTick(composerTop: 620)) == [.applyPerFrame(composerTop: 620)])
        }
        #expect(m.state == .dismissing)
    }

    // MARK: Release + settle

    @Test func liftFromDismissingEntersReleasing() {
        var m = observing()
        _ = m.handle(.linkTick(composerTop: 470)) // engage
        let lift = m.handle(.endedDragging)
        #expect(m.state == .releasing)
        #expect(lift.isEmpty)
    }

    @Test func releasingSettlesThenStopsAndReconciles() {
        var m = KeyboardSyncMachine(engageThreshold: 4, settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = m.handle(.beganDragging(keyboardOpen: true))
        _ = m.handle(.linkTick(composerTop: 400)) // baseline
        _ = m.handle(.linkTick(composerTop: 460)) // engage -> dismissing
        _ = m.handle(.endedDragging)              // -> releasing
        #expect(m.handle(.linkTick(composerTop: 800)) == [.applyPerFrame(composerTop: 800)]) // moved, reset
        #expect(m.handle(.linkTick(composerTop: 800)) == [.applyPerFrame(composerTop: 800)]) // still 1
        #expect(m.handle(.linkTick(composerTop: 800)) == [.applyPerFrame(composerTop: 800)]) // still 2
        let settle = m.handle(.linkTick(composerTop: 800))                                   // 3 -> settle
        #expect(settle == [.stopLink, .reconcile])
        #expect(m.state == .idle)
    }

    @Test func regrabDuringReleasingReturnsToDismissing() {
        var m = observing()
        _ = m.handle(.linkTick(composerTop: 470)) // engage
        _ = m.handle(.endedDragging)              // releasing
        let regrab = m.handle(.beganDragging(keyboardOpen: true))
        #expect(m.state == .dismissing)
        #expect(regrab.isEmpty) // link already live
    }

    // MARK: Notification guard

    @Test func frameChangeObeyedInIdleAndScrolling() {
        var idle = KeyboardSyncMachine()
        #expect(idle.handle(.keyboardFrameWillChange(keyboardTop: 250)) == [.applyAnimated(.keyboardTop(250))])

        var scrolling = observing()
        #expect(scrolling.handle(.keyboardFrameWillChange(keyboardTop: 250)) == [.applyAnimated(.keyboardTop(250))])
        #expect(scrolling.state == .scrolling)
    }

    @Test func frameChangeIgnoredWhileDismissingAndReleasing() {
        var m = observing()
        _ = m.handle(.linkTick(composerTop: 470)) // dismissing
        #expect(m.handle(.keyboardFrameWillChange(keyboardTop: 250)) == [.ignoreKeyboardNotification])
        _ = m.handle(.endedDragging)              // releasing
        #expect(m.handle(.keyboardFrameWillChange(keyboardTop: 900)) == [.ignoreKeyboardNotification])
    }

    // MARK: Height-change partition

    @Test func heightChangeKeyboardDownIdleAppliesResting() {
        var m = KeyboardSyncMachine()
        #expect(m.handle(.composerHeightChanged(keyboardOpen: false)) == [.invalidateComposerIntrinsicSize, .applyAnimated(.resting)])
    }

    @Test func heightChangeKeyboardUpIdleOnlyInvalidates() {
        var m = KeyboardSyncMachine()
        #expect(m.handle(.composerHeightChanged(keyboardOpen: true)) == [.invalidateComposerIntrinsicSize])
    }

    @Test func heightChangeWhileScrollingOnlyInvalidates() {
        var m = observing()
        #expect(m.handle(.composerHeightChanged(keyboardOpen: true)) == [.invalidateComposerIntrinsicSize])
        #expect(m.state == .scrolling)
    }

    // MARK: Tap

    @Test func tapRequestsResignThenDock() {
        var m = KeyboardSyncMachine()
        #expect(m.handle(.tapToDismiss) == [.resignTextView, .dockAccessory])
    }

    // MARK: Defensive

    @Test func strayTickInIdleIsNoop() {
        var m = KeyboardSyncMachine()
        #expect(m.handle(.linkTick(composerTop: 300)).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func endedDraggingInIdleIsNoop() {
        var m = KeyboardSyncMachine()
        #expect(m.handle(.endedDragging).isEmpty)
        #expect(m.state == .idle)
    }

    // MARK: Full scenarios

    /// Keyboard-open scroll-up: enters scrolling, the composer never moves, the
    /// inset is written ZERO times, lift returns to idle. This is the case the
    /// old model got wrong (it wrote the inset every frame).
    @Test func scenarioKeyboardOpenScrollUpWritesNothing() {
        var m = KeyboardSyncMachine()
        var writes = 0
        _ = m.handle(.beganDragging(keyboardOpen: true))
        for top in [400.0, 400, 401, 399, 400, 402, 400, 398, 400] {
            for e in m.handle(.linkTick(composerTop: top)) where e == .applyPerFrame(composerTop: top) { writes += 1 }
        }
        _ = m.handle(.endedDragging)
        #expect(writes == 0)
        #expect(m.state == .idle)
    }

    /// Full interactive dismiss: scroll -> engage -> dismiss frames -> lift ->
    /// settle. The committed keyboard frame mid-release is ignored, reconciled at
    /// the end.
    @Test func scenarioInteractiveDismiss() {
        var m = KeyboardSyncMachine(engageThreshold: 4, settleEpsilon: 0.5, settleFrameThreshold: 3)
        var log: [KeyboardSyncEffect] = []
        log += m.handle(.beganDragging(keyboardOpen: true))     // startLink
        log += m.handle(.linkTick(composerTop: 400))            // baseline
        for top in stride(from: CGFloat(410), through: 760, by: 50) {
            log += m.handle(.linkTick(composerTop: top))        // engages then applyPerFrame...
        }
        log += m.handle(.endedDragging)                         // -> releasing
        log += m.handle(.keyboardFrameWillChange(keyboardTop: 900)) // ignored mid-release
        for _ in 0..<6 { log += m.handle(.linkTick(composerTop: 800)) } // settle

        #expect(log.filter { $0 == .startLink }.count == 1)
        #expect(log.filter { $0 == .stopLink }.count == 1)
        #expect(log.filter { $0 == .reconcile }.count == 1)
        #expect(log.contains(.ignoreKeyboardNotification))
        #expect(m.state == .idle)
    }
}
