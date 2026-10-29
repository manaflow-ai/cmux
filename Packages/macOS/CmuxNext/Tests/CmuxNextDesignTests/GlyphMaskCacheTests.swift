import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

/// Chrome labels that show the same glyphs share one image from a byte-capped LRU
/// (Skia's `SkStrikeCache`), held by the theme scope tree the composition root gives it to.
@MainActor @Suite struct GlyphMaskCacheTests {
    private static let shape = LabelText.Shape(lines: 1, wraps: false, lineBreak: .byTruncatingTail, alignment: .natural,
                                               tightens: false, truncatesLastVisibleLine: true, strategy: [])

    private static func key(_ text: String, weight: Int = 0) -> GlyphMaskCache.Key {
        GlyphMaskCache.Key(text: NSAttributedString(string: text), shape: shape, size: CGSize(width: 80, height: 16),
                           scale: 2, weight: weight)
    }

    /// A `side` x `side` image of exactly `side * side * 4` bytes.
    private static func image(side: Int) -> CGImage? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    private static func label(_ text: String, in scope: ThemeScope) -> ChromeLabel {
        let label = ChromeLabel(labelWithString: text)
        label.wantsLayer = true
        label.frame = NSRect(x: 0, y: 0, width: 120, height: 16)
        scope.root(label)
        return label
    }

    /// The image the label's glyph layer shows (its fill layer's mask).
    private static func glyphContents(of label: ChromeLabel) -> AnyObject? {
        (label.layer?.sublayers?.first?.mask?.contents).map { $0 as AnyObject }
    }

    @Test func equalLabelsRasterizeOnce() throws {
        let scope = ThemeScope(level: .room)
        let masks = GlyphMaskCache()
        scope.sharedGlyphMasks = masks
        let first = Self.label("Terminal", in: scope), second = Self.label("Terminal", in: scope)
        first.updateLayer()
        second.updateLayer()

        #expect(masks.rasterizations == 1)
        #expect(masks.count == 1)
        let shown = try #require(Self.glyphContents(of: first))
        #expect(Self.glyphContents(of: second) === shown, "the second label does not show the shared image")

        let other = Self.label("Browser", in: scope)
        other.updateLayer()
        #expect(masks.rasterizations == 2)
    }

    /// A child scope (a workspace, a pane strip) draws through its ancestor's cache.
    @Test func aChildScopeSharesItsParentsCache() {
        let room = ThemeScope(level: .room)
        let masks = GlyphMaskCache()
        room.sharedGlyphMasks = masks
        let workspace = ThemeScope(level: .workspace, parent: room)
        #expect(workspace.glyphMasks === masks)

        Self.label("main", in: room).updateLayer()
        Self.label("main", in: workspace).updateLayer()
        #expect(masks.rasterizations == 1)
    }

    /// Without a shared cache a label keeps its own images, as before the feature.
    @Test func withoutACacheEachLabelDrawsItsOwn() {
        let scope = ThemeScope(level: .room)
        let first = Self.label("Terminal", in: scope), second = Self.label("Terminal", in: scope)
        first.updateLayer()
        second.updateLayer()
        #expect(scope.glyphMasks == nil)
        #expect(Self.glyphContents(of: first) != nil)
        #expect(Self.glyphContents(of: first) !== Self.glyphContents(of: second))
    }

    @Test func theByteLimitHoldsAndTheLeastRecentlyUsedGoesFirst() throws {
        let tile = 16 * 16 * 4
        let masks = GlyphMaskCache(fullCapacityBytes: tile * 2)
        _ = masks.image(for: Self.key("a")) { Self.image(side: 16) }
        _ = masks.image(for: Self.key("b")) { Self.image(side: 16) }
        _ = masks.image(for: Self.key("a")) { Issue.record("a hit draws"); return nil }  // a is the newest now
        _ = masks.image(for: Self.key("c")) { Self.image(side: 16) }

        #expect(masks.totalBytes == tile * 2)
        #expect(masks.count == 2)
        #expect(masks.rasterizations == 3)
        _ = masks.image(for: Self.key("a")) { Issue.record("a was evicted"); return nil }
        _ = masks.image(for: Self.key("b")) { Self.image(side: 16) }
        #expect(masks.rasterizations == 4, "b, the least recently used, was not the one evicted")
        #expect(masks.totalBytes <= masks.capacityBytes)
    }

    /// An image larger than the cap is shown and not kept.
    @Test func anImageOverTheCapIsNotKept() throws {
        let masks = GlyphMaskCache(fullCapacityBytes: 100)
        let image = masks.image(for: Self.key("wide")) { Self.image(side: 16) }
        #expect(image != nil)
        #expect(masks.count == 0)
        #expect(masks.totalBytes == 0)
    }

    /// Each stem weight is its own image; a weight drawn before is a hit.
    @Test func eachStemWeightIsItsOwnImage() {
        let masks = GlyphMaskCache()
        _ = masks.image(for: Self.key("a", weight: 1)) { Self.image(side: 4) }
        _ = masks.image(for: Self.key("a", weight: 2)) { Self.image(side: 4) }
        _ = masks.image(for: Self.key("a", weight: 1)) { Issue.record("weight 1 drew again"); return nil }
        #expect(masks.rasterizations == 2)
        #expect(Self.key("a", weight: 1).showsSameText(as: Self.key("a", weight: 2)))
        #expect(!Self.key("a", weight: 1).showsSameText(as: Self.key("b", weight: 1)))
    }

    /// Memory pressure: a lowered limit frees nothing, and a release slice drops the oldest idle images
    /// to it.
    @Test func aReleaseSliceDropsTheOldestIdleToTheLimit() {
        let tile = 16 * 16 * 4
        let clock = ManualClock()
        let masks = GlyphMaskCache(fullCapacityBytes: tile * 4, clock: clock)
        for name in ["a", "b", "c", "d"] { _ = masks.image(for: Self.key(name)) { Self.image(side: 16) } }
        #expect(masks.memoryUsage?.footprintBytes == tile * 4)
        clock.advance(by: MemoryLimit.workingSet * 2)

        let half = MemoryLimit(percent: 50)
        masks.updateMemoryLimit(half)
        #expect(masks.count == 4, "a new limit frees nothing")
        #expect(masks.releaseMemory(within: MemoryReleaseSlice(limit: half, isExpired: { false })) == .done)
        #expect(masks.totalBytes == tile * 2)
        _ = masks.image(for: Self.key("d")) { Issue.record("the newest was dropped"); return nil }
        _ = masks.image(for: Self.key("c")) { Issue.record("the second newest was dropped"); return nil }
    }

    /// The working set stays at any limit, critical included (MemoryLimit.workingSet): an image used just
    /// now survives a critical release, and a hit after it draws nothing. Once it goes idle, the next
    /// release takes it.
    @Test func aCriticalReleaseKeepsTheWorkingSet() {
        let tile = 16 * 16 * 4
        let clock = ManualClock()
        let masks = GlyphMaskCache(fullCapacityBytes: tile * 4, clock: clock)
        for name in ["a", "b", "c"] { _ = masks.image(for: Self.key(name)) { Self.image(side: 16) } }
        clock.advance(by: MemoryLimit.workingSet * 2)
        _ = masks.image(for: Self.key("b")) { Issue.record("b drew again"); return nil }  // b is in use now

        let critical = MemoryReleaseSlice(limit: .criticalThreshold, isExpired: { false })
        masks.updateMemoryLimit(.criticalThreshold)
        #expect(masks.releaseMemory(within: critical) == .keptWorkingSet(agesOutIn: MemoryLimit.workingSet))
        #expect(masks.count == 1)
        _ = masks.image(for: Self.key("b")) { Issue.record("the image in use was dropped"); return nil }
        #expect(masks.rasterizations == 3)

        // At critical, a new image is in the working set too: it is kept, and its next use is a hit.
        _ = masks.image(for: Self.key("e")) { Self.image(side: 16) }
        _ = masks.image(for: Self.key("e")) { Issue.record("a new image was not kept at critical"); return nil }
        #expect(masks.count == 2)

        clock.advance(by: MemoryLimit.workingSet * 2)
        #expect(masks.releaseMemory(within: critical) == .done)
        #expect(masks.count == 0)
    }

    /// At a lowered limit an insert makes room from idle images: the cache grows only by its working set.
    @Test func aLoweredLimitStopsIdleGrowth() {
        let tile = 16 * 16 * 4
        let clock = ManualClock()
        let masks = GlyphMaskCache(fullCapacityBytes: tile * 4, clock: clock)
        for name in ["a", "b"] { _ = masks.image(for: Self.key(name)) { Self.image(side: 16) } }
        clock.advance(by: MemoryLimit.workingSet * 2)
        masks.updateMemoryLimit(.criticalThreshold)

        _ = masks.image(for: Self.key("c")) { Self.image(side: 16) }
        #expect(masks.totalBytes == tile * 2, "the insert grew past the size before it")
        _ = masks.image(for: Self.key("b")) { Issue.record("b, newer than a, was dropped first"); return nil }
        _ = masks.image(for: Self.key("d")) { Self.image(side: 16) }
        #expect(masks.count == 3, "images in the working set were dropped to make room")
    }
}
