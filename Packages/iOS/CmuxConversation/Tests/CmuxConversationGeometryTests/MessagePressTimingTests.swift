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
}

/// Real-iPhone bug: lifting mid-hold on a photo, link or file opened it as
/// well. In Messages, once the press has begun (0.15 s) a lift never opens
/// the item; a quicker tap still does.
@Suite struct MessagePressTapArbitrationTests {
    @Test func aBegunPressExcludesTaps() {
        #expect(!MessagePressTiming.recognizeTogether(.press, .tap, isGrowing: true))
        #expect(!MessagePressTiming.recognizeTogether(.tap, .press, isGrowing: true))
        #expect(!MessagePressTiming.recognizeTogether(.press, .tap, isGrowing: false))
    }

    @Test func theTwoPressClocksAndDragsStillShare() {
        #expect(MessagePressTiming.recognizeTogether(.press, .press, isGrowing: true))
        #expect(MessagePressTiming.recognizeTogether(.press, .pan, isGrowing: true))
        #expect(!MessagePressTiming.recognizeTogether(.pan, .press, isGrowing: false))
        // Taps keep sharing with everything else (single tap beside double tap).
        #expect(MessagePressTiming.recognizeTogether(.tap, .tap, isGrowing: false))
        #expect(MessagePressTiming.recognizeTogether(.tap, .pan, isGrowing: false))
    }

    @Test func onlyAQuickTapOpensTheItem() {
        #expect(MessagePressTiming.tapOpensItem(afterHolding: 0.1))
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.15))
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.2))
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.3))
        #expect(!MessagePressTiming.tapOpensItem(afterHolding: 0.5))
    }
}
