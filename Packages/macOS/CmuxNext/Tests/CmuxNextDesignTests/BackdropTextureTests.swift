import AppKit
import Testing
@testable import CmuxNextDesign

@MainActor
struct BackdropTextureTests {
    @Test func defaultTextureUsesAQuietOrderedDither() {
        #expect(BackdropTexture.default.filter == .orderedDither4x4)
        #expect(BackdropTexture.default.strength == 0.12)
    }

    @Test(arguments: [BackdropTextureFilter.none, .orderedDither4x4, .orderedDither8x8, .halftone, .grain])
    func filtersAreRepresentedByStablePlans(_ filter: BackdropTextureFilter) {
        let texture = BackdropTexture(filter: filter, strength: 2)
        #expect(texture.filter == filter)
        #expect(texture.strength == 1)
        #expect(texture.id == "\(filter.rawValue):1.000")
    }

    @Test func invalidStrengthFallsBackToTheSafeRange() {
        #expect(BackdropTexture(filter: .grain, strength: -0.5).strength == 0)
        #expect(BackdropTexture(filter: .grain, strength: .infinity).strength == 1)
        #expect(BackdropTexture(filter: .grain, strength: .nan).strength == 0)
    }

    @Test func textureCacheRendersOncePerSourceAndPlan() throws {
        let source = try #require(Self.image())
        let cache = BackdropTextureCache()
        let texture = BackdropTexture(filter: .orderedDither4x4, strength: 0.2)
        let first = try #require(cache.image(for: "fixture", source: source, texture: texture))
        let second = try #require(cache.image(for: "fixture", source: source, texture: texture))
        #expect(first === second)
        #expect(cache.renderCount == 1)
        #expect(first.size == source.size)
    }

    @Test func changingFilterCreatesASeparateCachedImage() throws {
        let source = try #require(Self.image())
        let cache = BackdropTextureCache()
        let dithered = try #require(cache.image(for: "fixture", source: source,
                                                texture: BackdropTexture(filter: .orderedDither4x4, strength: 0.2)))
        let halftone = try #require(cache.image(for: "fixture", source: source,
                                                texture: BackdropTexture(filter: .halftone, strength: 0.2)))
        #expect(dithered !== halftone)
        #expect(cache.renderCount == 2)
    }

    private static func image() -> NSImage? {
        let image = NSImage(size: NSSize(width: 32, height: 20))
        image.lockFocus()
        NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.7, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 32, height: 20).fill()
        NSColor(calibratedRed: 0.9, green: 0.75, blue: 0.15, alpha: 1).setFill()
        NSRect(x: 8, y: 5, width: 16, height: 10).fill()
        image.unlockFocus()
        return image
    }
}
