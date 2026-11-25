import CmuxMobileDesign
import CoreGraphics
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif

/// Leo, 2026-11-22: "chatgpt you csn swipe down inside the composer to
/// collapse it. we need that here too." Every composer's text view
/// (`ComposerReturnTextView`) collapses on a downward swipe that starts at
/// the text's top (`ComposerSwipeCollapse`).
@Suite struct ComposerSwipeCollapseTests {
    let rule = ComposerSwipeCollapse()

    func collapses(_ x: CGFloat, _ y: CGFloat, velocity: CGFloat = 0, atTop: Bool = true, held: TimeInterval = 0.05) -> Bool {
        rule.collapses(translation: CGPoint(x: x, y: y), velocity: CGPoint(x: 0, y: velocity), beganAtTop: atTop, heldFor: held)
    }

    @Test func aSlowDragDownPastTheDistanceCollapses() {
        #expect(collapses(0, 24))
        #expect(collapses(4, 60))
        #expect(!collapses(0, 20))
    }

    @Test func aShortFlickDownCollapses() {
        #expect(collapses(0, 10, velocity: 600))
        #expect(!collapses(0, 10, velocity: 200))
        #expect(!collapses(0, 4, velocity: 2_000), "a tap's jitter is not a flick")
    }

    @Test func upwardOrSidewaysDragsNeverCollapse() {
        #expect(!collapses(0, -60, velocity: -800))
        #expect(!collapses(60, 30), "a sideways caret drag")
        #expect(!collapses(-40, 40))
    }

    @Test func aLongDraftScrolledDownScrollsUpFirst() {
        #expect(!collapses(0, 80, velocity: 900, atTop: false))
    }

    @Test func aHeldPressIsTheLoupeNotACollapse() {
        #expect(!collapses(0, 80, held: 0.5))
        #expect(collapses(0, 80, held: 0.2))
    }
}

#if os(iOS)
@MainActor
@Suite struct ComposerSwipeCollapseViewTests {
    /// Off until the person turns on Settings → Composer → Swipe Down to Collapse (Leo, 2026-11-24:
    /// "don't unilaterally MERGE ui stuff yet ... having people be able to easily toggle" it).
    @Test func theSwipeIsOffUntilTheSettingIsOn() {
        let key = CmuxMobilePreferences.Key.swipeDownCollapsesComposer
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let view = ComposerReturnTextView(policy: ComposerReturnPolicy(style: .chat, maxLines: 6))
        #expect(view.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer && $0.cancelsTouchesInView == false } == true)
        #expect(!view.swipeCollapseEnabled, "off by default")
        UserDefaults.standard.set(true, forKey: key)
        #expect(view.swipeCollapseEnabled, "the setting turns it on in every composer")
        view.collapsesOnSwipeDown = false
        #expect(!view.swipeCollapseEnabled, "one composer can opt out")
    }
}
#endif
