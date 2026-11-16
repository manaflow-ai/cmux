import CmuxScreenKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The Mac's own cursor image on a screen stream: cached by id, named by the
/// telepointers, drawn at the Mac's size at any zoom.
struct ScreenStreamCursorTests {
    static func cursor(_ id: String, w: Double = 28.0 / 1512, h: Double = 40.0 / 982) throws -> ScreenStreamCursor {
        let context = try #require(CGContext(data: nil, width: 56, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let shape = ScreenCursorShape(id: id, png: (data as Data).base64EncodedString(), w: w, h: h,
                                      hx: 5.0 / 28, hy: 5.0 / 40, pw: 28, ph: 40)
        return try #require(ScreenStreamCursor(shape))
    }

    @Test func aBadShapeIsNoCursor() {
        let shape = ScreenCursorShape(id: "x", png: "AAAA", w: 0.1, h: 0.1, hx: 0, hy: 0, pw: 1, ph: 1)
        #expect(ScreenStreamCursor(shape) == nil)
    }

    @Test func theTelepointersPickTheShapeTheyName() throws {
        var cache = ScreenStreamCursorCache()
        #expect(!cache.select(nil), "a Mac that sends no shapes: no change")
        #expect(cache.current == nil)
        #expect(!cache.add(try Self.cursor("arrow")), "not named yet")
        #expect(cache.select("arrow") && cache.current?.id == "arrow")
        #expect(!cache.select("arrow"), "unchanged")
        // Named before it arrived (telepointers are unordered): the arrow stays until it does.
        #expect(!cache.select("ibeam") && cache.current?.id == "arrow")
        #expect(cache.add(try Self.cursor("ibeam")) && cache.current?.id == "ibeam")
        #expect(cache.select("arrow") && cache.current?.id == "arrow", "back to a shape it has")
        cache.reset()
        #expect(cache.current == nil && !cache.select("ibeam"), "a new stream starts over")
    }

    /// The viewer keeps every shape the host remembers sending (64), and
    /// more: naming a shape keeps it, as the host's own memory does.
    @Test func theCacheKeepsWhatTheHostRemembers() throws {
        var cache = ScreenStreamCursorCache()
        _ = cache.add(try Self.cursor("arrow"))
        for index in 0 ..< ScreenStreamCursorCache.capacity + 10 {
            _ = cache.add(try Self.cursor("s\(index)"))
            if index % 8 == 0 { _ = cache.select("arrow") }
        }
        #expect(cache.select("s20") && cache.current?.id == "s20")
        #expect(cache.select("arrow") && cache.current?.id == "arrow", "named often: still here")
        #expect(!cache.select("s0") && cache.current?.id == "arrow", "the oldest unnamed one left: the arrow stays")
    }

    /// A 28x40-point arrow on a 1512x982-point Mac streamed at 3024x1964:
    /// 56x80 frame pixels, its hotspot 10, 10 from the image's top left.
    @Test func itIsAsLargeAsTheMacShowsIt() throws {
        let cursor = try Self.cursor("arrow")
        let placement = cursor.placement(at: CGPoint(x: 1000, y: 500), frame: CGSize(width: 3024, height: 1964))
        #expect(abs(placement.rect.width - 56) < 1e-6 && abs(placement.rect.height - 80) < 1e-6)
        #expect(abs(placement.rect.minX - 990) < 1e-6 && abs(placement.rect.minY - 490) < 1e-6)
        #expect(abs(placement.pixelsPerPoint - 2) < 1e-6)
        // The same Mac streamed at half size (the viewer's demand): half as large, still on the hotspot.
        let half = cursor.placement(at: CGPoint(x: 500, y: 250), frame: CGSize(width: 1512, height: 982))
        #expect(abs(half.rect.width - 28) < 1e-6 && abs(half.rect.minX - 495) < 1e-6 && abs(half.pixelsPerPoint - 1) < 1e-6)
    }
}
