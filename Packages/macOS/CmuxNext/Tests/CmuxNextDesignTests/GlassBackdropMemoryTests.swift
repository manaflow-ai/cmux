import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Testing

/// The glass lens stills are one lossless memory consumer that reports the bytes of its encoded
/// data URLs. A new limit frees nothing; a release drops the least recently asked encoded stills down to the limit's
/// share of the capacity, never one still encoding; a still asked again after a release is encoded again.
@MainActor @Suite struct GlassBackdropMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        let limit: MemoryLimit
        private(set) var names: [String] = []

        init(limit: MemoryLimit = .default) {
            self.limit = limit
        }

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            names.append(entry.name)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    private static func art(width: Int) throws -> NSImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 32))
        let image = try #require(context.makeImage())
        return NSImage(cgImage: image, size: NSSize(width: width, height: 32))
    }

    /// Asks for `art`'s still and waits until it is encoded.
    private static func encoded(_ art: NSImage, in stills: GlassBackdropImages) async throws -> String {
        let ready = AsyncStream<Void>.makeStream()
        let asked = stills.still(art) { ready.continuation.yield() }
        let first = try #require(asked)
        if let url = first.dataURL { return url }
        for await _ in ready.stream { break }
        return try #require(stills.still(art, ready: {})?.dataURL)
    }

    @Test func theStillsAreALosslessSmallManagedConsumerNamedInTheReport() {
        let traits = GlassBackdropImages.memoryTraits
        #expect(traits.retention == .lossless && traits.dataAccess == .none && traits.recreateCost == .cheap)
        #expect(traits.estimatedUsage == .small && traits.isManaged)
        let registry = FakeRegistry()
        GlassBackdropImages(maxPixelSize: 64).registerMemoryConsumer(with: registry)
        #expect(registry.names == [GlassBackdropImages.memoryConsumerName])
    }

    @Test func theStillsReportTheBytesOfTheirDataURLs() async throws {
        let stills = GlassBackdropImages(maxPixelSize: 64, capacity: 4)
        stills.registerMemoryConsumer(with: FakeRegistry())
        #expect(stills.memoryUsage == .empty)
        let first = try await Self.encoded(Self.art(width: 64), in: stills)
        let second = try await Self.encoded(Self.art(width: 48), in: stills)
        #expect(stills.memoryUsage == MemoryUsage(footprintBytes: first.utf8.count + second.utf8.count, entries: 2))
    }

    @Test func aNewLimitFreesNothingAndAReleaseDropsTheOldestDownToTheLimit() async throws {
        let stills = GlassBackdropImages(maxPixelSize: 64, capacity: 4)
        stills.registerMemoryConsumer(with: FakeRegistry())
        let arts = try [64, 56, 48, 40].map { try Self.art(width: $0) }
        var urls: [String] = []
        for art in arts { urls.append(try await Self.encoded(art, in: stills)) }
        stills.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(stills.memoryUsage?.entries == 4, "a new limit frees nothing")
        #expect(stills.releaseMemory(within: Self.slice(50)) == .done)
        #expect(stills.memoryUsage == MemoryUsage(footprintBytes: urls[2].utf8.count + urls[3].utf8.count, entries: 2))
        // The newest two stay under their keys; the oldest is encoded again under a new one.
        #expect(stills.still(arts[3], ready: {})?.dataURL == urls[3])
        let asked = stills.still(arts[0], ready: {})
        let again = try #require(asked)
        #expect(again.dataURL == nil, "a dropped still is encoded again when next asked")
    }

    @Test func theCriticalLimitDropsEveryEncodedStillButNotOneEncoding() async throws {
        let stills = GlassBackdropImages(maxPixelSize: 64, capacity: 4)
        stills.registerMemoryConsumer(with: FakeRegistry())
        _ = try await Self.encoded(Self.art(width: 64), in: stills)
        let ready = AsyncStream<Void>.makeStream()
        let encoding = try #require(stills.still(try Self.art(width: 48)) { ready.continuation.yield() })
        #expect(encoding.dataURL == nil)
        #expect(stills.releaseMemory(within: Self.slice(0)) == .done)
        #expect(stills.memoryUsage?.entries == 1, "the still encoding stays: its pages wait for it")
        for await _ in ready.stream { break }
        #expect((stills.memoryUsage?.footprintBytes ?? 0) > 0, "its encode ends and its page gets it")
    }

    @Test func aNewStillAtTheCriticalLimitNeverDropsOneEncoding() async throws {
        let stills = GlassBackdropImages(maxPixelSize: 64, capacity: 4)
        stills.registerMemoryConsumer(with: FakeRegistry(limit: .criticalThreshold))
        let readyA = AsyncStream<Void>.makeStream(), readyB = AsyncStream<Void>.makeStream()
        let artA = try Self.art(width: 64), artB = try Self.art(width: 48)
        let a = try #require(stills.still(artA) { readyA.continuation.yield() })
        let b = try #require(stills.still(artB) { readyB.continuation.yield() })
        #expect(a.dataURL == nil && b.dataURL == nil)
        #expect(stills.memoryUsage?.entries == 2, "both encodes run past the held limit of 1")
        for await _ in readyA.stream { break }
        for await _ in readyB.stream { break }
        #expect(stills.still(artA, ready: {})?.dataURL?.isEmpty == false, "the first page gets its still")
        #expect(stills.still(artA, ready: {})?.key == a.key)
        // The next new still trims the encoded ones down to the held limit.
        _ = stills.still(try Self.art(width: 40), ready: {})
        #expect(stills.memoryUsage?.entries == 1)
    }

    @Test func anExpiredSliceDropsNothing() async throws {
        let stills = GlassBackdropImages(maxPixelSize: 64, capacity: 4)
        stills.registerMemoryConsumer(with: FakeRegistry())
        _ = try await Self.encoded(Self.art(width: 64), in: stills)
        #expect(stills.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(stills.memoryUsage?.entries == 1)
    }
}
