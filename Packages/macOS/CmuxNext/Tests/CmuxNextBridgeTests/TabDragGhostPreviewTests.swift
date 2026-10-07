import CoreGraphics
import Testing
@testable import CmuxNextBridge

/// A tab with no content preview (App Store, an agent chat) unfolded an
/// empty Liquid Glass card off a strip: a large grey box. The ghost keeps
/// the compact tab until a preview arrives, then unfolds.
struct TabDragGhostPreviewTests {
    private let tab = CGRect(x: 0, y: 0, width: 120, height: 28)

    @Test func withoutAPreviewTheGhostStaysTheTab() {
        var motion = TabDragGhostMotion(rect: tab, cardness: 0, reduceMotion: true)
        motion.hasPreview = false
        motion.setTarget(tab.offsetBy(dx: 40, dy: 40), cardness: 1, jump: true)
        #expect(motion.presentedCardness == 0)
        // A landing that asks for the card fades the tab instead.
        motion.setTarget(tab.offsetBy(dx: 80, dy: 80), cardness: 1, opacity: 0, scale: 0.7, jump: true)
        #expect(motion.presentedCardness == 0)
    }

    @Test func thePreviewArrivingUnfoldsTheCardItWasAskedFor() {
        var motion = TabDragGhostMotion(rect: tab, cardness: 0)
        motion.hasPreview = false
        motion.setTarget(tab.offsetBy(dx: 40, dy: 40), cardness: 1, jump: true)
        motion.hasPreview = true
        for _ in 0..<240 { _ = motion.step(1.0 / 120) }
        #expect(motion.presentedCardness == 1)

        // Over a strip it folds back regardless.
        motion.setTarget(tab, cardness: 0, jump: true)
        for _ in 0..<240 { _ = motion.step(1.0 / 120) }
        #expect(motion.presentedCardness == 0)
    }
}
