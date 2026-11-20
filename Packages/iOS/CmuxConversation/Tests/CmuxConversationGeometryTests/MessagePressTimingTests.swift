import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Reference: iOS 26.5 simulator Messages, held outgoing bubbles recorded at
/// 60 fps, and UIKit's context-menu click driver constants on the transcript.
@Suite struct MessagePressTimingTests {
    @Test func usesUIKitsClickDriverTimes() {
        #expect(MessagePressTiming.liftBegins == 0.15)
        #expect(MessagePressTiming.clickDown == 0.4)
        #expect(MessagePressTiming.clickTimeout == 0.725)
    }

    @Test func liftingBeforeTheClickCancels() {
        // A 0.33 s hold: the bubble grew, then settled back with no menu.
        #expect(MessagePressTiming.release(afterHolding: 0.33) == .cancel)
        #expect(MessagePressTiming.release(afterHolding: 0.39) == .cancel)
    }

    @Test func liftingAfterTheClickOpensTheMenu() {
        // 0.53 s and 0.65 s holds: the menu opened at the lift.
        #expect(MessagePressTiming.release(afterHolding: 0.4) == .open)
        #expect(MessagePressTiming.release(afterHolding: 0.65) == .open)
    }

    @Test func heldGrowthMatchesMessages() {
        // 208 -> 222.7 pt and 278 -> 291.5 pt wide while held.
        #expect(abs(208 * MessagePressTiming.pressScale(for: CGSize(width: 208, height: 39)) - 222.7) < 1)
        #expect(abs(278 * MessagePressTiming.pressScale(for: CGSize(width: 278, height: 39)) - 291.5) < 1)
    }

    @Test func liftedGrowthMatchesMessages() {
        // 208 -> 234.5 pt and 278 -> 303.5 pt wide with the menu open.
        #expect(abs(208 * MessagePressTiming.liftScale(for: CGSize(width: 208, height: 39)) - 234.5) < 1)
        #expect(abs(278 * MessagePressTiming.liftScale(for: CGSize(width: 278, height: 39)) - 303.5) < 1)
    }

    @Test func smallLiftedBubblesStopAtMessagesMaximumScale() {
        // iOS 26.5 Messages, menu open: "Got it" 69.7 -> 79.3-80 pt, "Thanks"
        // 83.3 -> 96 pt, "I can do 7" 119.7 -> ~137 pt. The 26 pt growth
        // (95.7, 109.3, 145.7 pt) would lift them far larger.
        #expect(abs(69.67 * MessagePressTiming.liftScale(for: CGSize(width: 69.67, height: 40.33)) - 80) < 1)
        #expect(abs(83.33 * MessagePressTiming.liftScale(for: CGSize(width: 83.33, height: 40.33)) - 96) < 1)
        #expect(abs(119.67 * MessagePressTiming.liftScale(for: CGSize(width: 119.67, height: 40.33)) - 137) < 1.5)
    }
}

/// Real-iPhone bug: lifting mid-hold on a photo, link or file sometimes
/// opened it. iOS 26.5 Messages (photo bubble, verified from the transcript
/// before each hold): lifts after 0.13, 0.23, 0.25, 0.34 and 0.36 s open the
/// photo viewer even though the bubble had started growing; a 0.55 s lift
/// opens the menu and never the photo. So the item opens only for a lift
/// before the click (0.4 s); once the menu takes the touch, nothing opens.
@Suite struct MessagePressTapArbitrationTests {
    @Test func tapsStillShareTheTouchWithThePress() {
        // The tap decides at the lift (tapOpensItem), so it must stay alive.
        #expect(MessagePressTiming.recognizeTogether(.press, .tap, isGrowing: true))
        #expect(MessagePressTiming.recognizeTogether(.tap, .press, isGrowing: false))
    }

    @Test func theTwoPressClocksAndDragsStillShare() {
        #expect(MessagePressTiming.recognizeTogether(.press, .press, isGrowing: true))
        #expect(MessagePressTiming.recognizeTogether(.press, .pan, isGrowing: true))
        #expect(!MessagePressTiming.recognizeTogether(.pan, .press, isGrowing: false))
        #expect(MessagePressTiming.recognizeTogether(.tap, .tap, isGrowing: false))
        #expect(MessagePressTiming.recognizeTogether(.tap, .pan, isGrowing: false))
    }

    @Test func aLiftBeforeTheClickStillOpensTheItem() {
        #expect(MessagePressTiming.tapOpensItem(afterHolding: 0.1))
        #expect(MessagePressTiming.tapOpensItem(afterHolding: 0.23))
        #expect(MessagePressTiming.tapOpensItem(afterHolding: 0.36))
    }

    @Test func aLiftThatOpensTheMenuNeverOpensTheItem() {
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.4))
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.55))
        // Held past the click timeout: the menu is already open.
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.9))
    }
}
