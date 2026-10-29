import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The backdrop image store is a lossless memory consumer. It holds at most the limit's
/// share of ``BackdropImageStore/fullCount`` decoded pictures, a new limit frees nothing, a release lets go
/// of one picture per turn down to the limit, a picture a window still shows is found again without a
/// second decode, and one no window shows decodes again on its next read.
@MainActor @Suite struct BackdropImageMemoryTests {
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

    /// A folder of small solid PNG pictures, one per selection.
    private struct Pictures {
        let root: URL
        let selections: [BackdropSelection]

        init(count: Int) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("backdrop-memory-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            selections = try (0..<count).map { index in
                let file = root.appendingPathComponent("picture-\(index).png")
                try Self.write(gray: CGFloat(index) / CGFloat(max(count, 1)), to: file)
                return .file(path: file.path)
            }
        }

        private static func write(gray: CGFloat, to file: URL) throws {
            let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let image = try #require(context.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    /// Loads every selection of `pictures` into `store` and keeps none of the images.
    private static func load(_ pictures: Pictures, into store: BackdropImageStore) async throws {
        for selection in pictures.selections {
            _ = try #require(await store.image(selection))
        }
    }

    @Test func theStoreIsALosslessManagedConsumer() {
        let traits = BackdropImageStore.memoryTraits
        #expect(traits.retention == .lossless)
        #expect(traits.dataAccess == .none)
        #expect(traits.recreateCost == .cheap)
        #expect(traits.isManaged)
    }

    @Test func registeringNamesTheStoreInTheReport() {
        let registry = FakeRegistry()
        BackdropImageStore(maxPixelSize: 64).registerMemoryConsumer(with: registry)
        #expect(registry.names == [BackdropImageStore.memoryConsumerName])
    }

    @Test func anUnregisteredStoreHoldsEveryPicture() async throws {
        let pictures = try Pictures(count: BackdropImageStore.fullCount + 2)
        defer { pictures.remove() }
        let store = BackdropImageStore(maxPixelSize: 64)
        try await Self.load(pictures, into: store)
        #expect(store.memoryUsage?.entries == BackdropImageStore.fullCount + 2)
    }

    @Test func atTheFullLimitTheStoreHoldsTheMostRecentFullCount() async throws {
        let pictures = try Pictures(count: BackdropImageStore.fullCount + 2)
        defer { pictures.remove() }
        let store = BackdropImageStore(maxPixelSize: 64)
        store.registerMemoryConsumer(with: FakeRegistry())
        try await Self.load(pictures, into: store)
        let usage = try #require(store.memoryUsage)
        #expect(usage.entries == BackdropImageStore.fullCount)
        #expect(usage.footprintBytes >= BackdropImageStore.fullCount * 16 * 16 * 4)
        // The newest pictures stay held; the oldest, shown by no window, are freed.
        #expect(store.cached(try #require(pictures.selections.last)) != nil)
        #expect(store.cached(pictures.selections[0]) == nil)
    }

    @Test func aNewLimitFreesNothingAndAReleaseLetsGoOnePicturePerTurn() async throws {
        let pictures = try Pictures(count: 3)
        defer { pictures.remove() }
        let store = BackdropImageStore(maxPixelSize: 64)
        store.registerMemoryConsumer(with: FakeRegistry())
        try await Self.load(pictures, into: store)

        store.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(store.memoryUsage?.entries == 3)

        #expect(store.releaseMemory(within: Self.slice(0)) == .yield)
        #expect(store.memoryUsage?.entries == 2)
        #expect(store.releaseMemory(within: Self.slice(0)) == .yield)
        #expect(store.releaseMemory(within: Self.slice(0)) == .done)
        #expect(store.memoryUsage == .empty)
        #expect(store.releaseMemory(within: Self.slice(0)) == .done)
    }

    @Test func anExpiredSliceLetsGoOfNothing() async throws {
        let pictures = try Pictures(count: 2)
        defer { pictures.remove() }
        let store = BackdropImageStore(maxPixelSize: 64)
        store.registerMemoryConsumer(with: FakeRegistry())
        try await Self.load(pictures, into: store)
        #expect(store.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(store.memoryUsage?.entries == 2)
    }

    @Test func atLimitZeroNothingIsHeldAndAHitAfterReleaseDecodesAgain() async throws {
        let pictures = try Pictures(count: 1)
        defer { pictures.remove() }
        let selection = try #require(pictures.selections.first)
        let store = BackdropImageStore(maxPixelSize: 64)
        store.registerMemoryConsumer(with: FakeRegistry(limit: MemoryLimit(percent: 0)))
        // The caller drops the picture at once: no window shows it.
        _ = try #require(await store.image(selection))
        #expect(store.memoryUsage == .empty)
        #expect(store.cached(selection) == nil)
        #expect(await store.image(selection) != nil)
        #expect(store.memoryUsage == .empty)
    }

    @Test func aPictureAWindowShowsIsFoundAgainWithoutASecondDecode() async throws {
        let pictures = try Pictures(count: 2)
        defer { pictures.remove() }
        let selection = try #require(pictures.selections.first)
        let store = BackdropImageStore(maxPixelSize: 64)
        store.registerMemoryConsumer(with: FakeRegistry())
        // The window keeps its picture as its art view's contents.
        let shown = try #require(await store.image(selection))
        _ = try #require(await store.image(pictures.selections[1]))
        while store.releaseMemory(within: Self.slice(0)) != .done {}
        #expect(store.memoryUsage == .empty)

        #expect(store.cached(selection) === shown)
        #expect(await store.image(selection) === shown)
        // Back at the full limit, the found picture is held and counted again.
        store.updateMemoryLimit(.default)
        #expect(store.cached(selection) === shown)
        #expect(store.memoryUsage?.entries == 1)
    }
}
