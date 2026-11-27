import CmuxNextDictation
import CoreGraphics
import Testing

@Suite struct VoiceRoomFrameSignatureTests {
    private func image(grey: CGFloat, box: CGRect? = nil) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: grey, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        if let box {
            context.setFillColor(gray: 1 - grey, alpha: 1)
            context.fill(box)
        }
        return try #require(context.makeImage())
    }

    @Test func theSameFrameIsUnchangedAndAnInvertedOneIsFullyChanged() throws {
        let black = try #require(VoiceRoomFrameSignature(image: image(grey: 0)))
        let white = try #require(VoiceRoomFrameSignature(image: image(grey: 1)))
        #expect(black.difference(to: black) == 0)
        #expect(black.difference(to: white) > 0.99)
    }

    @Test func aNewWindowIsAChangeButACursorBlinkIsNot() throws {
        let screen = try #require(VoiceRoomFrameSignature(image: image(grey: 0)))
        let window = try #require(VoiceRoomFrameSignature(image: image(grey: 0, box: CGRect(x: 40, y: 40, width: 160, height: 100))))
        let caret = try #require(VoiceRoomFrameSignature(image: image(grey: 0, box: CGRect(x: 100, y: 100, width: 2, height: 10))))
        #expect(screen.difference(to: window) > 0.02)
        #expect(screen.difference(to: caret) < 0.02)
    }

    @Test func pixelsMustFillTheThumbnail() {
        #expect(VoiceRoomFrameSignature(pixels: [0, 1, 2]) == nil)
    }
}
