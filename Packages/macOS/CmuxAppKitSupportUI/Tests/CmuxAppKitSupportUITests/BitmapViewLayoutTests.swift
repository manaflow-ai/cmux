import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// `BitmapView` replaces `NSImageView` for hosted icons, so it must keep the
/// `.scaleProportionallyDown` + `.alignCenter` layout icons were tuned for.
@Suite struct BitmapViewLayoutTests {
    @Test func smallerImageKeepsItsSizeAndIsCentered() {
        let rect = BitmapView.drawRect(imageSize: NSSize(width: 14, height: 14), in: NSRect(x: 0, y: 0, width: 22, height: 22))
        #expect(rect == NSRect(x: 4, y: 4, width: 14, height: 14))
    }

    @Test func largerImageShrinksProportionally() {
        let rect = BitmapView.drawRect(imageSize: NSSize(width: 40, height: 20), in: NSRect(x: 0, y: 0, width: 20, height: 20))
        #expect(rect.size == NSSize(width: 20, height: 10))
        #expect(rect.midY == 10)
    }
}
