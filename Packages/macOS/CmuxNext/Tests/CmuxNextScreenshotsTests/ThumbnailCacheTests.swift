import CmuxNextFileGrid
import CoreGraphics
import Foundation
import Testing

/// Counts renders and hands back a 1×1 image, so the cache's rules are tested without Quick Look.
nonisolated final class CountingGenerator: ThumbnailGenerating, @unchecked Sendable {
    // Test double: `renders` is read only after the awaited calls finish.
    private(set) var renders = 0
    private(set) var durationReads = 0
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        renders += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    func duration(for url: URL) async -> TimeInterval? {
        durationReads += 1
        return 7.4
    }
}

@Suite struct ThumbnailCacheTests {
    static func item(_ name: String, modified: TimeInterval = 1, kind: FileGridMediaKind? = nil) -> FileGridItem {
        FileGridItem(url: URL(fileURLWithPath: "/shots/\(name)"), kind: kind, size: 1,
                     modified: Date(timeIntervalSinceReferenceDate: modified), sourceID: "s")
    }

    @Test func rendersOnceAndRedrawsARewrittenFile() async {
        let generator = CountingGenerator()
        let cache = ThumbnailCache(capacity: 10, generator: generator)
        #expect(await cache.thumbnail(for: Self.item("a.png"), side: 100, scale: 2) != nil)
        _ = await cache.thumbnail(for: Self.item("a.png"), side: 100, scale: 2)
        #expect(await cache.renderCount == 1)
        #expect(await cache.cachedThumbnail(for: Self.item("a.png"), side: 100, scale: 2) != nil)
        _ = await cache.thumbnail(for: Self.item("a.png", modified: 2), side: 100, scale: 2)
        #expect(await cache.renderCount == 2)
    }

    @Test func concurrentAsksForOneTileShareARender() async {
        let generator = CountingGenerator(delay: .milliseconds(50))
        let cache = ThumbnailCache(capacity: 10, generator: generator)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = await cache.thumbnail(for: Self.item("a.png"), side: 100, scale: 2) } }
        }
        #expect(await cache.renderCount == 1)
    }

    @Test func staysWithinItsCapacity() async {
        let cache = ThumbnailCache(capacity: 16, generator: CountingGenerator())
        for index in 0..<100 { _ = await cache.thumbnail(for: Self.item("\(index).png"), side: 100, scale: 2) }
        #expect(await cache.count <= 16)
        // The newest tile survived eviction.
        #expect(await cache.cachedThumbnail(for: Self.item("99.png"), side: 100, scale: 2) != nil)
    }

    @Test func readsAMovieLengthOnceAndNoneForStills() async {
        let generator = CountingGenerator()
        let cache = ThumbnailCache(generator: generator)
        #expect(await cache.duration(for: Self.item("a.mov")) == 7.4)
        #expect(await cache.duration(for: Self.item("a.mov")) == 7.4)
        #expect(await cache.duration(for: Self.item("a.png")) == nil)
        #expect(generator.durationReads == 1)
    }
}
