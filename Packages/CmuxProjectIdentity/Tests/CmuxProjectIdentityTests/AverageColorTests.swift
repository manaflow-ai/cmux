import AppKit
import Testing
@testable import CmuxProjectIdentity

private func solidImage(_ color: NSColor, _ side: Int = 16) -> CGImage {
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        color.setFill(); rect.fill(); return true
    }
    var r = NSRect(x: 0, y: 0, width: side, height: side)
    return img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}

@Test func averageOfSolidRedIsRed() {
    let hex = AverageColor().hexString(of: solidImage(.red))
    #expect(hex == "#FF0000")
}
@Test func averageOfSolidBlueIsBlue() {
    let hex = AverageColor().hexString(of: solidImage(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
    #expect(hex == "#0000FF")
}
