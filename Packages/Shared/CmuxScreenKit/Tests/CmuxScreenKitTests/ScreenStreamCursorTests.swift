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
        func select(_ id: String?) -> Bool { cache.select(id) }
        func add(_ id: String) throws -> Bool { cache.add(try Self.cursor(id)) }
        #expect(!select(nil), "a Mac that sends no shapes: no change")
        #expect(cache.current == nil)
        #expect(try !add("arrow"), "not named yet")
        #expect(select("arrow") && cache.current?.id == "arrow")
        #expect(!select("arrow"), "unchanged")
        // Named before it arrived (telepointers are unordered): the arrow stays until it does.
        #expect(!select("ibeam") && cache.current?.id == "arrow")
        #expect(try add("ibeam") && cache.current?.id == "ibeam")
        #expect(select("arrow") && cache.current?.id == "arrow", "back to a shape it has")
        cache.reset()
        #expect(cache.current == nil && !select("ibeam"), "a new stream starts over")
    }

    @Test func theSameShapeOnAnotherDisplayUpdatesItsPlacementOnce() throws {
        var cache = ScreenStreamCursorCache()
        func select(_ id: String) -> Bool { cache.select(id) }
        func add(_ cursor: ScreenStreamCursor) -> Bool { cache.add(cursor) }
        let original = try Self.cursor("arrow", w: 28.0 / 1512, h: 40.0 / 982)
        let resized = try Self.cursor("arrow", w: 28.0 / 756, h: 40.0 / 491)
        _ = add(original)
        #expect(select("arrow"))
        // The image and hotspot have the same id, but the streamed display is smaller.
        #expect(add(resized), "the session must notify the view of the new geometry")
        let current = try #require(cache.current)
        let placement = current.placement(at: CGPoint(x: 100, y: 100), frame: CGSize(width: 756, height: 491))
        #expect(abs(placement.rect.width - 28) < 1e-6 && abs(placement.rect.height - 40) < 1e-6)
        #expect(abs(placement.rect.minX - 95) < 1e-6 && abs(placement.rect.minY - 95) < 1e-6)
        #expect(abs(placement.pixelsPerPoint - 1) < 1e-6)
        // Decode another instance, so duplicate suppression cannot depend on CGImage identity.
        let duplicate = try Self.cursor("arrow", w: 28.0 / 756, h: 40.0 / 491)
        #expect(!add(duplicate), "identical drawing metadata does not notify again")
        #expect(!select("arrow"), "a repeated telepointer does not notify again")
    }

    /// The viewer keeps every shape the host remembers sending (64), and
    /// more: naming a shape keeps it, as the host's own memory does.
    @Test func theCacheKeepsWhatTheHostRemembers() throws {
        var cache = ScreenStreamCursorCache()
        func select(_ id: String) -> Bool { cache.select(id) }
        _ = cache.add(try Self.cursor("arrow"))
        for index in 0 ..< ScreenStreamCursorCache.capacity + 10 {
            _ = cache.add(try Self.cursor("s\(index)"))
            if index % 8 == 0 { _ = cache.select("arrow") }
        }
        #expect(select("s20") && cache.current?.id == "s20")
        #expect(select("arrow") && cache.current?.id == "arrow", "named often: still here")
        #expect(!select("s0") && cache.current?.id == "arrow", "the oldest unnamed one left: the arrow stays")
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
