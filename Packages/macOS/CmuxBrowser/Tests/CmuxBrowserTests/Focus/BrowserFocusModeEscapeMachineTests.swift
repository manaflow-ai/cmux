import AppKit
import Testing
@testable import CmuxBrowser

// The `decide(event:isActive:isExitArmed:)` entry point reads `NSEvent` fields
// (`timestamp`, `isARepeat`, `windowNumber`) that AppKit does not let a test set
// on a synthesized event, so the event-driven transitions are exercised through
// the app-side handler. These tests pin the deterministic, numeric surface the
// machine owns: the freshness window, the arming-state predicates, and the
// reset transforms, plus the side-effect token mappings.
@Suite("BrowserFocusModeEscapeMachine")
struct BrowserFocusModeEscapeMachineTests {
    @Test func freshnessRequiresAnArmTimestamp() {
        let machine = BrowserFocusModeEscapeMachine()
        #expect(!machine.escapeArmIsFresh(eventTimestamp: 100))
    }

    @Test func freshnessIsTrueWithinTheSequenceInterval() {
        let machine = BrowserFocusModeEscapeMachine(exitArmedAt: 10)
        #expect(machine.escapeArmIsFresh(eventTimestamp: 10))
        #expect(machine.escapeArmIsFresh(
            eventTimestamp: 10 + BrowserFocusModeEscapeMachine.escapeSequenceInterval
        ))
    }

    @Test func freshnessIsFalsePastTheSequenceInterval() {
        let machine = BrowserFocusModeEscapeMachine(exitArmedAt: 10)
        #expect(!machine.escapeArmIsFresh(
            eventTimestamp: 10 + BrowserFocusModeEscapeMachine.escapeSequenceInterval + 0.001
        ))
    }

    @Test func freshnessTreatsNonPositiveTimestampsAsFresh() {
        // Matches the legacy guard: an unreliable (<= 0) arm or event clock is
        // treated as fresh rather than forcing a re-arm.
        #expect(BrowserFocusModeEscapeMachine(exitArmedAt: 0).escapeArmIsFresh(eventTimestamp: 100))
        #expect(BrowserFocusModeEscapeMachine(exitArmedAt: 10).escapeArmIsFresh(eventTimestamp: 0))
    }

    @Test func freshnessClampsNegativeGapToFresh() {
        // An event predating the arm yields a negative gap; max(0, gap) == 0 is
        // within the interval, so it is fresh (no force re-arm).
        let machine = BrowserFocusModeEscapeMachine(exitArmedAt: 100)
        #expect(machine.escapeArmIsFresh(eventTimestamp: 50))
    }

    @Test func armingPredicatesReflectStoredState() {
        #expect(!BrowserFocusModeEscapeMachine().hasArmingState)
        #expect(!BrowserFocusModeEscapeMachine().hasArmedExitTimestamp)

        let armed = BrowserFocusModeEscapeMachine(exitArmedAt: 5)
        #expect(armed.hasArmingState)
        #expect(armed.hasArmedExitTimestamp)
    }

    @Test func clearedDropsBothFields() {
        let armed = BrowserFocusModeEscapeMachine(exitArmedAt: 5)
        let cleared = armed.cleared()
        #expect(cleared.exitArmedAt == nil)
        #expect(cleared.lastPlainEscapeFingerprint == nil)
        #expect(!cleared.hasArmingState)
    }

    @Test func disarmDropsOnlyTheArmTimestamp() {
        let fingerprint = BrowserFocusModePlainEscapeEventFingerprint(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )!
        )
        let armed = BrowserFocusModeEscapeMachine(
            exitArmedAt: 5,
            lastPlainEscapeFingerprint: fingerprint
        )
        let disarmed = armed.disarmedExitTimestamp()
        #expect(disarmed.exitArmedAt == nil)
        #expect(disarmed.lastPlainEscapeFingerprint == fingerprint)
        #expect(disarmed.hasArmingState)
        #expect(!disarmed.hasArmedExitTimestamp)
    }

    @Test func debugMarkerLogEventsMatchLegacyTokens() {
        #expect(BrowserFocusModeEscapeMachine.DebugMarker.escapeRepeat.logEvent == "browser.focusMode.escape.repeat")
        #expect(BrowserFocusModeEscapeMachine.DebugMarker.escapeDuplicate.logEvent == "browser.focusMode.escape.duplicate")
        #expect(BrowserFocusModeEscapeMachine.DebugMarker.escapeRearm.logEvent == "browser.focusMode.escape.rearm")
        #expect(BrowserFocusModeEscapeMachine.DebugMarker.escapeArm.logEvent == "browser.focusMode.escape.arm")
    }
}
