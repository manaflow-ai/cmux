import AppKit
import CmuxNextCompat
@testable import CmuxNextApps
import Foundation
import Testing

/// An app bundle's decoded images were kept until 65 were read, then all dropped,
/// outside the memory coordinator. Now they are one lossless consumer: least recently used first,
/// a new limit frees nothing, a release frees down to it, the critical limit keeps only the images
/// drawn in the last 2 s, and an image drawn after a release is read again.
@MainActor @Suite struct AppBundleImageCacheMemoryTests {
    /// The working set's clock, moved by hand.
    @MainActor private final class TestClock {
        var now = ContinuousClock.now

        func advance(_ duration: Duration = .seconds(3)) { now = now.advanced(by: duration) }
    }

    /// A bundle folder with `count` 8 x 8 PNG files, `0.png` ...
    private static func bundle(_ count: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-bundle-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        for index in 0..<count { try png.write(to: directory.appendingPathComponent("\(index).png")) }
        return directory
    }

    private static func slice(_ limit: MemoryLimit) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: limit) { false }
    }

    @Test func keepsTheNewestWithinItsLimitAndCountsDecodedBytes() throws {
        let directory = try Self.bundle(6)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let cache = AppBundleImageCache(maxCount: 4, now: { clock.now })
        for index in 0..<6 {
            clock.advance()
            #expect(cache.image(path: "\(index).png", in: directory) != nil)
        }
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 4 * 8 * 8 * 4, entries: 4))
        // A new limit frees nothing; the release drops the least recently used.
        _ = cache.image(path: "2.png", in: directory)
        clock.advance()
        cache.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(cache.memoryUsage?.entries == 4)
        #expect(cache.releaseMemory(within: Self.slice(MemoryLimit(percent: 50))) == .done)
        #expect(cache.memoryUsage?.entries == 2)
        #expect(cache.memoryUsage?.footprintBytes == 2 * 8 * 8 * 4)
    }

    @Test func theCriticalLimitKeepsTheWorkingSetAndAnImageDrawnTwiceIsReadOnce() throws {
        let directory = try Self.bundle(3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let cache = AppBundleImageCache(maxCount: 4, now: { clock.now })
        _ = cache.image(path: "0.png", in: directory)
        _ = cache.image(path: "1.png", in: directory)
        // Both were drawn less than 2 s ago: a critical release keeps them.
        #expect(cache.releaseMemory(within: Self.slice(.criticalThreshold)) == .done)
        #expect(cache.memoryUsage?.entries == 2)
        // Out of the working set, they go.
        clock.advance()
        #expect(cache.releaseMemory(within: Self.slice(.criticalThreshold)) == .done)
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0))
        // Still critical: an image drawn now is kept, so drawing it again reads no file.
        #expect(cache.image(path: "2.png", in: directory) != nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("2.png"))
        #expect(cache.image(path: "2.png", in: directory) != nil)
        #expect(cache.memoryUsage?.entries == 1)
        // A released image is read again from its file.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("0.png"))
        #expect(cache.image(path: "0.png", in: directory) == nil)
    }

    @Test func anExpiredSliceAsksForMore() throws {
        let directory = try Self.bundle(3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let cache = AppBundleImageCache(maxCount: 4, now: { clock.now })
        for index in 0..<3 { _ = cache.image(path: "\(index).png", in: directory) }
        clock.advance()
        #expect(cache.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { true }) == .more)
        #expect(cache.memoryUsage?.entries == 3)
    }
}
