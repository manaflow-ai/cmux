import CoreGraphics
import Testing

@testable import CmuxChatLab

/// Behavior of the keyboard/scroll sync state machine. Each test names one rule
/// from the model; together they pin every edge of the idle/dragging/releasing
/// graph, the notification guard, the keyboard up/down height partition, the
/// reconcile-on-exit, tap-to-dismiss, and the full dismissal traces.
///
/// What we are testing, enumerated:
///  1. Entry: a drag starts tracking only when the keyboard is up.
///  2. Finger-up enters releasing on `endedDragging` ALWAYS (the fling fix).
///  3. Releasing settles after N stationary frames; movement resets the count.
///  4. Dragging never settles while the finger is down.
///  5. Re-grab during a release returns to dragging without restarting the link.
///  6. Keyboard frame notifications are obeyed in idle, ignored while linked.
///  7. `keyboardVisible` is tracked by show/hide and gates drag entry.
///  8. Composer height changes apply the inset only when keyboard-down + idle.
///  9. Leaving a release reconciles the inset (absorbs the ignored commit).
/// 10. Tap dismisses only when the keyboard is up (resign + re-dock).
/// 11. Defensive no-ops: stray ticks, double-end, end-without-drag.
struct KeyboardSyncMachineTests {
    /// A machine with the keyboard already raised and settled (the common
    /// precondition for the drag tests).
    private func raised() -> KeyboardSyncMachine {
        var machine = KeyboardSyncMachine()
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.keyboardFrameWillChange(keyboardTop: 400))
        return machine
    }

    // MARK: 1. Entry into tracking

    @Test func beganDraggingWithKeyboardUpStartsTracking() {
        var machine = raised()
        let effects = machine.handle(.beganDragging)
        #expect(machine.state == .dragging)
        #expect(effects == [.startLink])
        #expect(machine.ownsInsetViaLink)
    }

    @Test func beganDraggingWithKeyboardDownStaysIdle() {
        var machine = KeyboardSyncMachine() // keyboard down
        let effects = machine.handle(.beganDragging)
        #expect(machine.state == .idle)
        #expect(effects.isEmpty) // no link for a plain history scroll
        #expect(!machine.ownsInsetViaLink)
    }

    @Test func draggingTickGluesInsetEveryFrame() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        let effects = machine.handle(.linkTick(composerTop: 420))
        #expect(effects == [.applyPerFrame(composerTop: 420)])
        #expect(machine.state == .dragging)
    }

    // MARK: 2. Finger-up enters releasing ALWAYS (the fling fix)

    @Test func endedDraggingEntersReleasingWithNoMomentumGate() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 420))
        // There is no `willDecelerate` parameter to gate on: a fling and a slow
        // lift are the same event. This is the regression the old
        // `if !decelerate` gating caused.
        let effects = machine.handle(.endedDragging)
        #expect(machine.state == .releasing)
        #expect(effects.isEmpty) // link keeps running into the release
    }

    // MARK: 3. Settle detection

    @Test func releasingSettlesAfterThresholdStationaryFrames() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 500)) // seeds lastComposerTop
        _ = machine.handle(.endedDragging)
        // Three stationary frames -> settle on the third.
        #expect(machine.handle(.linkTick(composerTop: 500)) == [.applyPerFrame(composerTop: 500)])
        #expect(machine.handle(.linkTick(composerTop: 500)) == [.applyPerFrame(composerTop: 500)])
        let third = machine.handle(.linkTick(composerTop: 500))
        #expect(third == [.stopLink, .reconcile])
        #expect(machine.state == .idle)
        #expect(!machine.ownsInsetViaLink)
    }

    @Test func releasingResetsSettleCountOnMovement() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 500))
        _ = machine.handle(.endedDragging)
        _ = machine.handle(.linkTick(composerTop: 500)) // stationary 1
        _ = machine.handle(.linkTick(composerTop: 540)) // moved -> reset
        // A fresh run of stationary frames is needed; the next two must not settle.
        #expect(machine.handle(.linkTick(composerTop: 540)) == [.applyPerFrame(composerTop: 540)])
        #expect(machine.handle(.linkTick(composerTop: 540)) == [.applyPerFrame(composerTop: 540)])
        #expect(machine.state == .releasing) // still riding the spring
    }

    @Test func movementUnderEpsilonCountsAsStationary() {
        var machine = KeyboardSyncMachine(settleEpsilon: 1.0, settleFrameThreshold: 2)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 500))
        _ = machine.handle(.endedDragging)
        _ = machine.handle(.linkTick(composerTop: 500.4)) // < epsilon -> stationary 1
        let settle = machine.handle(.linkTick(composerTop: 500.7)) // < epsilon -> stationary 2 -> settle
        #expect(settle == [.stopLink, .reconcile])
    }

    // MARK: 4. Dragging never settles while the finger is down

    @Test func draggingNeverSettlesEvenWhenComposerIsStationary() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        // Keyboard parked under a held finger: many identical frames, no settle.
        for _ in 0..<10 {
            #expect(machine.handle(.linkTick(composerTop: 450)) == [.applyPerFrame(composerTop: 450)])
        }
        #expect(machine.state == .dragging)
    }

    // MARK: 5. Re-grab during a release

    @Test func regrabDuringReleasingReturnsToDraggingWithoutRestartingLink() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 480))
        _ = machine.handle(.endedDragging)
        #expect(machine.state == .releasing)
        let regrab = machine.handle(.beganDragging)
        #expect(machine.state == .dragging)
        #expect(regrab.isEmpty) // link already live -> no second startLink
    }

    // MARK: 6. The notification guard (mutual exclusion of clocks)

    @Test func keyboardFrameChangeObeyedInIdle() {
        var machine = raised()
        let effects = machine.handle(.keyboardFrameWillChange(keyboardTop: 250))
        #expect(effects == [.applyAnimated(.keyboardTop(250))])
    }

    @Test func keyboardFrameChangeIgnoredWhileDragging() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        let effects = machine.handle(.keyboardFrameWillChange(keyboardTop: 250))
        #expect(effects == [.ignoreKeyboardNotification])
        #expect(machine.state == .dragging)
    }

    @Test func keyboardFrameChangeIgnoredWhileReleasing() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 480))
        _ = machine.handle(.endedDragging)
        let effects = machine.handle(.keyboardFrameWillChange(keyboardTop: 800))
        #expect(effects == [.ignoreKeyboardNotification])
        #expect(machine.state == .releasing)
    }

    @Test func guardLiftsAfterSettleSoNextFrameChangeIsObeyed() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 1)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 500))
        _ = machine.handle(.endedDragging)
        _ = machine.handle(.linkTick(composerTop: 500)) // settle (threshold 1)
        #expect(machine.state == .idle)
        // Back in idle: a fresh keyboard frame is obeyed again.
        let effects = machine.handle(.keyboardFrameWillChange(keyboardTop: 300))
        #expect(effects == [.applyAnimated(.keyboardTop(300))])
    }

    // MARK: 7. keyboardVisible tracking + gating

    @Test func showSetsVisibleAndHideClearsIt() {
        var machine = KeyboardSyncMachine()
        #expect(!machine.keyboardVisible)
        _ = machine.handle(.keyboardWillShow)
        #expect(machine.keyboardVisible)
        _ = machine.handle(.keyboardWillHide)
        #expect(!machine.keyboardVisible)
    }

    @Test func dragEntryFollowsCurrentVisibility() {
        var machine = KeyboardSyncMachine()
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.keyboardWillHide) // ended up down
        let effects = machine.handle(.beganDragging)
        #expect(machine.state == .idle)
        #expect(effects.isEmpty)
    }

    // MARK: 8. Height-change partition (no double-write while keyboard up)

    @Test func heightChangeWhileKeyboardDownAppliesResting() {
        var machine = KeyboardSyncMachine() // idle, keyboard down
        let effects = machine.handle(.composerHeightChanged)
        #expect(effects == [.invalidateComposerIntrinsicSize, .applyAnimated(.resting)])
    }

    @Test func heightChangeWhileKeyboardUpOnlyInvalidates() {
        var machine = raised() // idle, keyboard up
        let effects = machine.handle(.composerHeightChanged)
        // No inset apply here: the accessory resize fires its own frame change
        // that owns the inset. Applying .resting too would be the wrong target.
        #expect(effects == [.invalidateComposerIntrinsicSize])
    }

    @Test func heightChangeWhileDraggingOnlyInvalidates() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        let effects = machine.handle(.composerHeightChanged)
        #expect(effects == [.invalidateComposerIntrinsicSize]) // link owns the inset
    }

    // MARK: 9. Reconcile is emitted exactly once on release exit

    @Test func releaseExitEmitsReconcileOnce() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 2)
        _ = machine.handle(.keyboardWillShow)
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 500))
        _ = machine.handle(.endedDragging)
        _ = machine.handle(.linkTick(composerTop: 500)) // stationary 1
        let exit = machine.handle(.linkTick(composerTop: 500)) // stationary 2 -> settle
        #expect(exit == [.stopLink, .reconcile])
        // After settling, further ticks are inert (link is being torn down).
        #expect(machine.handle(.linkTick(composerTop: 500)).isEmpty)
    }

    // MARK: 10. Tap to dismiss

    @Test func tapWhileKeyboardUpRequestsResignThenDock() {
        var machine = raised()
        let effects = machine.handle(.tapToDismiss)
        #expect(effects == [.resignTextView, .dockAccessory])
        #expect(machine.state == .idle) // tap does not change the driver state
    }

    @Test func tapWhileKeyboardDownDoesNothing() {
        var machine = KeyboardSyncMachine()
        #expect(machine.handle(.tapToDismiss).isEmpty)
    }

    // MARK: 11. Defensive no-ops

    @Test func strayTickInIdleIsNoop() {
        var machine = raised()
        #expect(machine.handle(.linkTick(composerTop: 300)).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func endedDraggingWithoutDragIsNoop() {
        var machine = raised()
        #expect(machine.handle(.endedDragging).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func doubleEndedDraggingStaysReleasing() {
        var machine = raised()
        _ = machine.handle(.beganDragging)
        _ = machine.handle(.endedDragging)
        #expect(machine.state == .releasing)
        #expect(machine.handle(.endedDragging).isEmpty) // second end is inert
        #expect(machine.state == .releasing)
    }

    // MARK: Full scenario traces

    /// Slow drag down, lift with no momentum, settle. The keyboard commit fires a
    /// `keyboardWillHide` + frame change MID-RELEASE, which must be ignored, then
    /// reconciled at the end.
    @Test func scenarioSlowDragDismiss() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = machine.handle(.keyboardWillShow)
        var effectLog: [KeyboardSyncEffect] = []

        effectLog += machine.handle(.beganDragging)           // startLink
        for top in stride(from: CGFloat(420), through: 760, by: 40) {
            effectLog += machine.handle(.linkTick(composerTop: top)) // applyPerFrame ...
        }
        effectLog += machine.handle(.endedDragging)           // -> releasing
        // Keyboard commits to dismissed: these must be ignored mid-release.
        _ = machine.handle(.keyboardWillHide)
        effectLog += machine.handle(.keyboardFrameWillChange(keyboardTop: 900)) // ignore
        // Spring rides to the dismissed position (first frame is movement from
        // the last drag sample) then holds for the 3-frame settle threshold.
        for _ in 0..<6 {
            effectLog += machine.handle(.linkTick(composerTop: 800))
        }

        #expect(effectLog.filter { $0 == .startLink }.count == 1)
        #expect(effectLog.filter { $0 == .stopLink }.count == 1)
        #expect(effectLog.filter { $0 == .reconcile }.count == 1)
        #expect(effectLog.contains(.ignoreKeyboardNotification))
        #expect(!machine.keyboardVisible)
        #expect(machine.state == .idle)
    }

    /// Fast fling down, lift, settle. Distinguished from the slow case only by
    /// representing momentum as extra ticks after the lift; the lift itself still
    /// enters releasing immediately (no decelerate gate).
    @Test func scenarioFlingDismiss() {
        var machine = KeyboardSyncMachine(settleEpsilon: 0.5, settleFrameThreshold: 3)
        _ = machine.handle(.keyboardWillShow)

        _ = machine.handle(.beganDragging)
        _ = machine.handle(.linkTick(composerTop: 430))
        let lift = machine.handle(.endedDragging)
        #expect(machine.state == .releasing) // immediate, even though a fling
        #expect(lift.isEmpty)
        // Momentum frames keep arriving; the spring rides them then settles.
        _ = machine.handle(.linkTick(composerTop: 650))
        _ = machine.handle(.linkTick(composerTop: 800))
        _ = machine.handle(.linkTick(composerTop: 800))
        _ = machine.handle(.linkTick(composerTop: 800))
        let settle = machine.handle(.linkTick(composerTop: 800))
        #expect(settle == [.stopLink, .reconcile])
        #expect(machine.state == .idle)
    }

    /// Typing until the bar grows, keyboard up: the height change must NOT apply
    /// the inset (only invalidate); the accessory-resize frame change is the sole
    /// inset writer. Proves the two writers can never contest a target.
    @Test func scenarioTypeToGrowHasSingleInsetWriter() {
        var machine = raised()
        var insetApplies = 0

        // The text view grew -> height change.
        for effect in machine.handle(.composerHeightChanged) {
            if case .applyAnimated = effect { insetApplies += 1 }
        }
        // The accessory got taller -> keyboard frame change with the new top.
        for effect in machine.handle(.keyboardFrameWillChange(keyboardTop: 360)) {
            if case .applyAnimated = effect { insetApplies += 1 }
        }
        #expect(insetApplies == 1) // exactly one, from the frame change
    }

    /// History scroll with the keyboard down never starts the link, so no
    /// per-frame inset work happens for an ordinary scroll.
    @Test func scenarioHistoryScrollKeyboardDownIsInert() {
        var machine = KeyboardSyncMachine()
        var effectLog: [KeyboardSyncEffect] = []
        effectLog += machine.handle(.beganDragging)
        effectLog += machine.handle(.endedDragging)
        #expect(effectLog.isEmpty)
        #expect(machine.state == .idle)
    }
}
