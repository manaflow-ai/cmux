import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextRemoteFetch
import Foundation
import Synchronization
import Testing

/// p07-memory-055: the favicon loader's per-profile LRU caches are one memory consumer
/// ("browser-favicons"). The limit scales how many icons each profile keeps: a new limit frees
/// nothing, a release frees down to it least recently used first, at 0 % nothing is kept, and an
/// icon dropped by a release is fetched again on the next ask.
@MainActor @Suite struct BrowserFaviconMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    private static let side = 32

    /// The decoded pixels of one test icon as the loader counts them: at most
    /// ``BrowserFaviconLoader/maximumPixels`` square, 4 bytes each.
    private static func iconBytes() throws -> Int {
        let image = try #require(BrowserFaviconLoader.decode(try png()))
        let bytes = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        let most = BrowserFaviconLoader.maximumPixels * BrowserFaviconLoader.maximumPixels * 4
        #expect(bytes > 0 && bytes <= most)
        return bytes
    }

    /// A 32 x 32 PNG, which the loader's decode keeps at 32 x 32.
    private static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private static func url(_ index: Int) throws -> URL {
        try #require(URL(string: "https://site\(index).example/favicon.png"))
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    /// A loader holding `count` icons of `profile`, icon 0 the least recently used.
    private static func filled(_ count: Int, profile: BrowserProfileID = .default) throws -> BrowserFaviconLoader {
        let loader = BrowserFaviconLoader()
        let data = try png()
        for index in 0..<count {
            #expect(loader.store(data, at: try url(index), profile: profile) != nil)
        }
        return loader
    }

    @Test func itRegistersOnceAndTakesTheCurrentLimit() throws {
        let registry = FakeRegistry()
        registry.limit = MemoryLimit(percent: 50)
        let loader = try Self.filled(0)
        loader.registerMemoryConsumer(with: registry)

        #expect(registry.entries.count == 1)
        #expect(registry.entries.first?.name == "browser-favicons")
        #expect(registry.entries.first?.traits.isManaged == true)
        #expect(loader.entriesPerProfileLimit == BrowserFaviconLoader.entriesPerProfile / 2)
    }

    @Test func atTheCriticalLimitNoIconIsKept() throws {
        let registry = FakeRegistry()
        registry.limit = .criticalThreshold
        let loader = BrowserFaviconLoader()
        loader.registerMemoryConsumer(with: registry)
        let url = try Self.url(0)

        #expect(loader.store(try Self.png(), at: url, profile: .default) != nil, "the caller still gets the icon")
        #expect(loader.cachedFavicon(at: url, profile: .default) == nil)
        #expect(loader.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0))
    }

    @Test func aNewLimitFreesNothingAndAReleaseDropsTheLeastRecentlyUsed() throws {
        let full = BrowserFaviconLoader.entriesPerProfile
        let iconBytes = try Self.iconBytes()
        let loader = try Self.filled(full)
        #expect(loader.memoryUsage == MemoryUsage(footprintBytes: full * iconBytes, entries: full))

        loader.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(loader.memoryUsage?.entries == full, "a new limit frees nothing")

        // Icon 0 becomes the most recently used, so the release keeps it.
        #expect(loader.cachedFavicon(at: try Self.url(0), profile: .default) != nil)
        #expect(loader.releaseMemory(within: Self.slice(50)) == .done)

        let kept = full / 2
        #expect(loader.memoryUsage == MemoryUsage(footprintBytes: kept * iconBytes, entries: kept))
        #expect(loader.cachedFavicon(at: try Self.url(0), profile: .default) != nil)
        #expect(loader.cachedFavicon(at: try Self.url(1), profile: .default) == nil)
        #expect(loader.cachedFavicon(at: try Self.url(full - 1), profile: .default) != nil)

        // A new icon past the lowered cap pushes one out instead of growing it.
        _ = loader.store(try Self.png(), at: try Self.url(full), profile: .default)
        #expect(loader.memoryUsage?.entries == kept)
    }

    @Test func anExpiredSliceStopsAndTheNextOneFinishes() throws {
        let loader = try Self.filled(4)

        #expect(loader.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(loader.memoryUsage?.entries == 4)
        #expect(loader.releaseMemory(within: Self.slice(0)) == .done)
        #expect(loader.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0))
    }

    @Test func eachProfileKeepsItsOwnScaledCap() throws {
        let other = BrowserProfileID(rawValue: UUID())
        let full = BrowserFaviconLoader.entriesPerProfile
        let iconBytes = try Self.iconBytes()
        let loader = try Self.filled(full)
        let data = try Self.png()
        for index in 0..<full { _ = loader.store(data, at: try Self.url(index), profile: other) }

        #expect(loader.releaseMemory(within: Self.slice(25)) == .done)
        #expect(loader.memoryUsage?.entries == 2 * (full / 4))

        loader.forget(profile: other)
        #expect(loader.memoryUsage == MemoryUsage(footprintBytes: (full / 4) * iconBytes, entries: full / 4))
    }

    @Test func anIconReleasedIsFetchedAgain() async throws {
        let transport = IconTransport(body: try Self.png())
        let loader = BrowserFaviconLoader(resolver: PublicResolver(), transport: transport)
        let url = try Self.url(0)

        #expect(await loader.favicon(at: url, profile: .default) != nil)
        #expect(await loader.favicon(at: url, profile: .default) != nil)
        #expect(transport.requestCount == 1, "a kept icon is not fetched again")

        #expect(loader.releaseMemory(within: Self.slice(0)) == .done)
        #expect(loader.cachedFavicon(at: url, profile: .default) == nil)

        #expect(await loader.favicon(at: url, profile: .default) != nil)
        #expect(transport.requestCount == 2, "a released icon is fetched again")
    }

    @Test func theLRUHoldsNothingAtLimitZeroAndTrimsOnlyWhenAsked() {
        var cache = LRUCache<Int, String>(capacity: 4)
        for key in 0..<4 { cache.set("\(key)", for: key) }

        cache.setLimit(2)
        #expect(cache.count == 4, "a lower limit frees nothing")
        #expect(cache.isOverLimit)
        let first = cache.removeLeastRecentlyUsed()
        let second = cache.removeLeastRecentlyUsed()
        #expect(first == "0" && second == "1")
        #expect(!cache.isOverLimit)

        let replaced = cache.set("replaced", for: 3)
        #expect(replaced == ["3"])
        let pushedOut = cache.set("4", for: 4)
        #expect(pushedOut == ["2"])

        cache.setLimit(0)
        let atZero = cache.set("5", for: 5)
        #expect(atZero == ["replaced", "4", "5"])
        #expect(cache.count == 0)

        cache.setLimit(99)
        #expect(cache.limit == cache.capacity)
    }
}

private nonisolated struct PublicResolver: RemoteAddressResolving {
    func resolve(_ host: String) async throws -> [RemoteAddress] { [.v4([1, 1, 1, 1])] }
}

/// Answers every request with one icon and counts the requests.
private nonisolated final class IconTransport: RemoteFetchTransport {
    private let body: Data
    private let count = Atomic<Int>(0)

    init(body: Data) { self.body = body }

    var requestCount: Int { count.load(ordering: .relaxed) }

    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
        count.add(1, ordering: .relaxed)
        return RemoteFetchResponse(status: 200, headers: ["content-type": "image/png"], body: body)
    }
}
