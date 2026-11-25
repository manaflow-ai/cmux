@testable import CmuxNextIcons
import CoreGraphics
import Testing

/// The shared icon bitmap cache stays bounded (lead, STATUS 7066): at most its count and byte limits, the least
/// recently used dropped first, and nothing kept after a memory pressure drop.
@Suite struct IconRastersBoundTests {
    private static func glyph(_ name: String) -> IconRasters.Glyph { .init(name: name, style: .line, symbol: nil) }
    private static let square = IconResolution.system("square")

    @Test func keepsAtMostItsLimitAndDropsTheLeastRecentlyUsed() throws {
        let cache = IconRasters(limit: 2, dropsOnMemoryPressure: false)
        let a = try #require(cache.bitmap(Self.glyph("a"), side: 12, scale: 1) { Self.square })
        _ = cache.bitmap(Self.glyph("b"), side: 12, scale: 1) { Self.square }
        // `a` is used again, so `b` is the least recently used when `c` comes.
        #expect(cache.bitmap(Self.glyph("a"), side: 12, scale: 1) { Self.square } === a)
        _ = cache.bitmap(Self.glyph("c"), side: 12, scale: 1) { Self.square }
        #expect(cache.count == 2)
        #expect(cache.bitmap(Self.glyph("a"), side: 12, scale: 1) { Self.square } === a, "the most recently used bitmap was dropped")
    }

    @Test func keepsAtMostItsByteLimit() {
        // A 12 pt bitmap at 2x is 24 x 24 x 4 bytes.
        let cache = IconRasters(byteLimit: 24 * 24 * 4 * 2, dropsOnMemoryPressure: false)
        for name in ["a", "b", "c", "d"] { _ = cache.bitmap(Self.glyph(name), side: 12, scale: 2) { Self.square } }
        #expect(cache.count <= 2)
    }

    @Test func aDropKeepsNothing() {
        let cache = IconRasters(dropsOnMemoryPressure: false)
        _ = cache.bitmap(Self.glyph("a"), side: 12, scale: 1) { Self.square }
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
