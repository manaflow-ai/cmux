import CmuxNextCompat
import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing

/// The changelog page's memo of inlined pictures (`ReleaseMediaStore.memoryConsumer`) is one lossless
/// memory consumer that reports the bytes of its `data:` URLs. A release drops the oldest pictures, and a page that
/// asks again reads them from the disk cache, never the network.
@MainActor @Suite struct ReleaseMediaMemoryTests {
    /// A network that serves one picture and counts its fetches.
    actor Network: AppcastFetching {
        let picture: Data
        private(set) var fetches = 0

        init(picture: Data) {
            self.picture = picture
        }

        func fetch(_ url: URL) async throws -> Data {
            fetches += 1
            return picture
        }
    }

    /// The bytes of a PNG as far as the store checks them (its signature, then padding).
    static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 2048))

    static func notes(_ picture: Data, file: String) throws -> ReleaseNotes {
        let hash = SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()
        let media = ReleaseNotes.Media(url: try #require(URL(string: "https://media.test/\(file)")), sha256: hash, kind: "image", alt: "")
        let highlight = ReleaseNotes.Highlight(id: "h1", title: "A highlight", body: "", media: [media], action: nil)
        return ReleaseNotes(version: 1, build: "4242", shortVersion: "1.0", date: "2026-10-26", highlights: [highlight], changes: [])
    }

    @Test func theMemoIsALosslessManagedConsumer() {
        let traits = ReleaseMediaStore.memoryTraits
        #expect(traits.retention == .lossless && traits.dataAccess == .none && traits.recreateCost == .cheap && traits.isManaged)
    }

    @Test func theMemoReportsItsBytesAndAReleaseReadsThePictureBackFromTheDisk() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "release-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let network = Network(picture: Self.picture)
        let store = ReleaseMediaStore(cache: cache, bundledDirectories: [], fetcher: network, siteBase: nil, reelBase: nil)
        let notes = try Self.notes(Self.picture, file: "a.png")

        let inlined = try #require(await store.inlined(notes).highlights.first?.media.first?.url)
        #expect(inlined.scheme == "data")
        let held = await store.memoryConsumer.updateMemoryLimit(.default)
        #expect(held == MemoryUsage(footprintBytes: inlined.absoluteString.utf8.count, entries: 1))

        let halved = await store.memoryConsumer.releaseMemory(downTo: MemoryLimit(percent: 50))
        #expect(halved == .empty, "half of one picture keeps none")

        let again = try #require(await store.inlined(notes).highlights.first?.media.first?.url)
        #expect(again == inlined, "the picture comes back the same")
        #expect(await network.fetches == 1, "it came back from the disk cache, not the network")
        let after = await store.memoryConsumer.releaseMemory(downTo: .default)
        #expect(after?.entries == 1)
    }

    @Test func aReleaseDropsTheOldestPicturesFirst() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "release-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let small = Self.picture, large = Self.picture + Data(repeating: 9, count: 512)
        let store = ReleaseMediaStore(cache: cache, bundledDirectories: [], fetcher: Network(picture: small), siteBase: nil, reelBase: nil)
        _ = await store.inlined(try Self.notes(small, file: "a.png"))
        let other = ReleaseMediaStore(cache: cache, bundledDirectories: [], fetcher: Network(picture: large), siteBase: nil, reelBase: nil)
        // The second picture comes from another fetch, into the same page's memo through the disk cache.
        _ = await other.inlined(try Self.notes(large, file: "b.png"))
        let newest = try #require(await store.inlined(try Self.notes(large, file: "b.png")).highlights.first?.media.first?.url)
        #expect(await store.memoryConsumer.updateMemoryLimit(.default)?.entries == 2)
        let kept = await store.memoryConsumer.releaseMemory(downTo: MemoryLimit(percent: 50))
        #expect(kept == MemoryUsage(footprintBytes: newest.absoluteString.utf8.count, entries: 1), "the newest picture stays")
        #expect(await other.memoryConsumer.updateMemoryLimit(.default)?.entries == 1, "another page's memo is its own")
    }
}
