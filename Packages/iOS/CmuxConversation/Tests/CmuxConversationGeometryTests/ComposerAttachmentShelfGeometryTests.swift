import CoreGraphics
import Foundation
import Testing
@testable import CmuxConversationGeometry

/// Values from Messages on the iOS 26.5 and 27.0 simulators (shelf
/// accessibility frames, `CKUIBehavior`, 60 fps recordings of the Photos
/// drawer) and a real iPhone 17 Pro Max screenshot.
@Suite struct ComposerAttachmentShelfGeometryTests {
    typealias G = ComposerAttachmentShelfGeometry
    typealias M = ComposerAttachmentShelfMotion

    @Test func bandMatchesTheMessagesField() {
        // Field 208.3 pt with a 40.3 pt text row: 6 + 155 + 6 + 1 + 40.3.
        #expect(G.bandHeight == 168)
        #expect(G.dividerY == 167)
        #expect(G.bandHeight + 40.287 - 208.287 < 0.001)
    }

    @Test func previewsSitSixPointsApartAtTheirPhotoAspect() {
        // A 4:3 photo is 206.7 pt wide in Messages; a 2:3 one 103.3 pt.
        let frames = G.previewFrames(aspectRatios: [4.0 / 3, 2.0 / 3], shelfWidth: 348)
        #expect(frames[0] == CGRect(x: 6, y: 0, width: 207, height: 155))
        #expect(frames[1] == CGRect(x: 219, y: 0, width: 103, height: 155))
        #expect(G.contentWidth(frames: frames) == 328)
    }

    @Test func previewWidthIsClampedToTheShelf() {
        #expect(G.previewWidth(aspectRatio: 10, shelfWidth: 348) == 336)
        #expect(G.previewWidth(aspectRatio: 0.1, shelfWidth: 348) == 60)
    }

    @Test func offsetsScrollToTheEndAndClampAfterRemoval() {
        // Three 4:3 previews overflow a 348 pt shelf by 285.
        #expect(G.endOffset(contentWidth: 633, shelfWidth: 348) == 285)
        #expect(G.endOffset(contentWidth: 200, shelfWidth: 348) == 0)
        #expect(G.clampedOffset(285, contentWidth: 420, shelfWidth: 348) == 72)
        #expect(G.clampedOffset(285, contentWidth: 328, shelfWidth: 348) == 0)
    }

    @Test func onlyTheLastOfSeveralExitsFromTheFirstSlot() {
        let frames = G.previewFrames(aspectRatios: [4.0 / 3, 4.0 / 3, 2.0 / 3], shelfWidth: 348)
        #expect(G.exitFrame(removedIndex: 1, frames: frames) == frames[1])
        let last = G.exitFrame(removedIndex: 2, frames: frames)
        #expect(last.origin.x == 6)
        #expect(last.size == frames[2].size)
        let single = [frames[0]]
        #expect(G.exitFrame(removedIndex: 0, frames: single) == frames[0])
    }

    @Test func shelfSpringIsCriticallyDamped() {
        // Field top fits of Messages: ω 18.2 rad/s, no overshoot.
        #expect(abs(2 * Double.pi / M.springResponse - 18.21) < 0.01)
        #expect(M.progress(at: 0) == 0)
        #expect(abs(M.progress(at: 0.1) - 0.543) < 0.005)
        var previous: CGFloat = 0
        for step in 1...100 {
            let p = M.progress(at: Double(step) * 0.01)
            #expect(p >= previous && p <= 1)
            previous = p
        }
    }
}

/// The Photos drawer under the composer: Messages' app-card sheet sits at
/// its "keyboard" detent, so its height follows the keyboard it replaces.
/// Measured sheet frames (keyboard frame from UIKeyboardWillChangeFrame):
/// iPhone 17 Pro 26.5 keyboard 335 -> {8, 544.3, 386, 321.7}; 27.0 keyboard
/// 328 -> {8, 551.1, 386, 314.9}; iPhone 17 Pro Max 27.0 keyboard 347 ->
/// {8, 613.6, 424, 334.4}; 26.5 keyboard 345 -> {8, 617.5, 424, 330.5}; a
/// real iPhone 17 Pro Max on 27 with a 318 pt keyboard -> top 643.3 of 956
/// (304.7 tall). The field keeps the place the keyboard gave it, 16 pt above
/// the keyboard's top, so about 21.3 pt above the sheet.
@Suite struct PhotoDrawerGeometryTests {
    @Test func drawerHeightFollowsTheKeyboard() {
        let cases: [(screen: CGFloat, keyboard: CGFloat, top: CGFloat)] = [
            (874, 335, 544.3), (874, 328, 551.1), (956, 347, 613.6), (956, 345, 617.5), (956, 318, 643.3),
        ]
        for c in cases {
            let height = PhotoDrawerGeometry.height(keyboardHeight: c.keyboard)
            let top = c.screen - PhotoDrawerGeometry.inset - height
            #expect(abs(top - c.top) < 1.3, "keyboard \(c.keyboard): top \(top) vs Messages \(c.top)")
        }
        #expect(PhotoDrawerGeometry.inset == 8)
    }

    @Test func fieldStaysWhereTheKeyboardLeftIt() {
        // Field bottom 16 pt above the keyboard's top, sheet top 5.3 pt below it.
        #expect(abs(PhotoDrawerGeometry.fieldGap - 21.3) < 0.2)
        let height = PhotoDrawerGeometry.height(keyboardHeight: 335)
        #expect(abs((874 - 8 - height - PhotoDrawerGeometry.fieldGap) - (874 - 335 - 16)) < 0.2)
    }

    @Test func noDockedKeyboardFallsBackToTheTypicalOne() {
        // Before any keyboard was shown, or with a hardware keyboard's short bar.
        #expect(abs(PhotoDrawerGeometry.height(keyboardHeight: 0) - 321.7) < 0.1)
        #expect(abs(PhotoDrawerGeometry.height(keyboardHeight: 60) - 321.7) < 0.1)
    }
}

/// Messages' Photos drawer is a sheet: pulled down it follows the finger
/// (the composer riding on its top) and, let go, it closes when the drag
/// plus its projected glide passes half the sheet, else it springs back.
/// iOS 27.0 17 Pro: a 120 pt pull held still springs back (sheet 315 pt).
@Suite struct PhotoDrawerDragTests {
    @Test func followsTheFingerDownAndResistsUp() {
        #expect(PhotoDrawerGeometry.dragOffset(translation: 80) == 80)
        let up = PhotoDrawerGeometry.dragOffset(translation: -100)
        #expect(up < 0 && up > -30)
    }

    @Test func aSlowShortPullSpringsBack() {
        #expect(!PhotoDrawerGeometry.shouldClose(offset: 120, velocity: 0, height: 315))
    }

    @Test func aLongPullCloses() {
        #expect(PhotoDrawerGeometry.shouldClose(offset: 170, velocity: 0, height: 315))
    }

    @Test func aFlickCloses() {
        #expect(PhotoDrawerGeometry.shouldClose(offset: 30, velocity: 900, height: 315))
        #expect(!PhotoDrawerGeometry.shouldClose(offset: 100, velocity: -400, height: 315))
    }
}
