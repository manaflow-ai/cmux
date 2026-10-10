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
