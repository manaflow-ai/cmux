import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextFavicons
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42435: one failed fetch of a tab's icon (offline at launch, a timeout)
/// left every strip and sidebar row on the globe for that address for the rest of the session: the store remembered
/// the failure until 255 other failures pushed it out, and nothing a row read ever changed again. A failure now holds
/// off refetches for ``TabFaviconStore/failureMemory``; when it ends, the rows that read the missing icon map again,
/// and that read fetches it.
@MainActor @Suite struct TabFaviconStoreRetryTests {
    static let address = "https://open.example/cdn/favicon32.png"

    @Test func aRowLeftOnTheGlobeByAFailedFetchGetsTheIconWhenTheFailureMemoryEnds() async throws {
        let loader = FlakyLoader()
        let clock = ManualClock()
        let store = TabFaviconStore(loader: loader, clock: clock)

        #expect(store.image(for: Self.address, profile: .default) == nil, "nothing yet: the first fetch starts")
        await loader.until { loader.calls == 1 && !store.isFetching(Self.address, profile: .default) }
        #expect(loader.calls == 1)

        // The row reads the icon under its observation, as a sidebar row and a strip do: still the globe.
        loader.succeeds = true
        let mapsAgain = MapsAgain()
        withObservationTracking {
            #expect(store.image(for: Self.address, profile: .default) == nil, "a fresh failure is not fetched again at once")
        } onChange: {
            mapsAgain.fire()
        }
        #expect(loader.calls == 1)

        try? await clock.waitForSleeper()
        clock.advance(by: TabFaviconStore.failureMemory)
        await loader.until { mapsAgain.fired }
        #expect(mapsAgain.fired, "the row that shows the globe maps again when the failure memory ends")

        _ = store.image(for: Self.address, profile: .default)
        await loader.until { loader.calls == 2 && !store.isFetching(Self.address, profile: .default) }
        #expect(loader.calls == 2, "its read fetches the icon again")
        #expect(store.image(for: Self.address, profile: .default) != nil, "the icon shows instead of the globe")
    }

    /// Another page of the same site (a Spotify album after the home page's icon fetch failed) loads the icon
    /// itself: its row and strip item show it at once, not after the failure memory (up to 30 minutes) ends.
    @Test func aPageThatLoadedTheIconItselfShowsItWhileTheFailureIsRemembered() async throws {
        let loader = FlakyLoader()
        let store = TabFaviconStore(loader: loader, clock: ManualClock())
        _ = store.image(for: Self.address, profile: .default)
        await loader.until { loader.calls == 1 && !store.isFetching(Self.address, profile: .default) }

        let album = MockBrowserEngine(kind: .cef).makeMockTab(
            BrowserTabConfiguration(initialURL: URL(string: "https://open.example/album/1")))
        let mapsAgain = MapsAgain()
        withObservationTracking {
            #expect(store.image(for: Self.address, profile: .default, tab: album) == nil, "the album's icon is not loaded yet")
        } onChange: {
            mapsAgain.fire()
        }

        // The album page's own fetch of the same address lands in the shared favicon cache.
        loader.cached = FlakyLoader.icon()
        album.favicon = loader.cached
        await loader.until { mapsAgain.fired }
        #expect(mapsAgain.fired, "the album's row maps again when its page loads the icon")
        #expect(store.image(for: Self.address, profile: .default, tab: album) != nil, "the icon shows instead of the globe")
        #expect(loader.calls == 1, "no second fetch: the page's own icon is used")
    }

    /// 500 pages with no icon (500 hibernated tabs) kept one timer each, so the idle app woke 8 times a second and
    /// each wake mapped every row again: 31.7% of a core on the infinite-tabs bench. Their failures end together.
    @Test func manyFailedIconsEndTheirMemoryInOneWake() async throws {
        let loader = FlakyLoader()
        let clock = ManualClock()
        let store = TabFaviconStore(loader: loader, clock: clock)
        let addresses = (0..<300).map { "https://site\($0).example/favicon.ico" }
        for address in addresses { _ = store.image(for: address, profile: .default) }
        await loader.until { loader.calls == addresses.count && !addresses.contains { store.isFetching($0, profile: .default) } }
        try? await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "one timer for every failure of a backoff step")

        let maps = MapsAgain()
        withObservationTracking {
            for address in addresses { _ = store.image(for: address, profile: .default) }
        } onChange: {
            maps.fire()
        }
        #expect(loader.calls == addresses.count, "no failure is fetched again inside its memory")
        // The first failure started the timer, so the rest (failed while it ran) end one memory after it.
        clock.advance(by: TabFaviconStore.failureMemory)
        await loader.until { maps.fired }
        _ = store.image(for: addresses[0], profile: .default)
        _ = store.image(for: addresses[1], profile: .default)
        await loader.until { loader.calls == addresses.count + 1 && !store.isFetching(addresses[0], profile: .default) }
        #expect(loader.calls == addresses.count + 1, "only the failure whose memory ended is fetched again")
        let mapsOnceMore = MapsAgain()
        withObservationTracking {
            _ = store.image(for: addresses[1], profile: .default)
        } onChange: {
            mapsOnceMore.fire()
        }
        try? await clock.waitForSleeper()
        clock.advance(by: TabFaviconStore.failureMemory)
        await loader.until { mapsOnceMore.fired }
        for address in addresses { _ = store.image(for: address, profile: .default) }
        await loader.until { loader.calls == addresses.count * 2 }
        #expect(loader.calls == addresses.count * 2, "the rest end together, one memory later")
    }

    /// A URL that keeps failing (a site with no icon) is held off longer each time, not fetched every minute.
    @Test func aURLThatKeepsFailingIsHeldOffLongerEachTime() {
        #expect(TabFaviconStore.failureMemory(after: 1) == TabFaviconStore.failureMemory)
        #expect(TabFaviconStore.failureMemory(after: 2) == TabFaviconStore.failureMemory * 2)
        #expect(TabFaviconStore.failureMemory(after: 40) == TabFaviconStore.longestFailureMemory)
    }
}

/// Whether the row's observation fired (its `onChange` runs on whichever thread wrote).
private nonisolated final class MapsAgain: Sendable {
    private let state = Mutex(false)
    var fired: Bool { state.withLock { $0 } }
    func fire() { state.withLock { $0 = true } }
}

/// Fails until `succeeds`, then answers a 1x1 icon.
@MainActor private final class FlakyLoader: BrowserFaviconLoading {
    var calls = 0
    var succeeds = false
    /// What the shared cache holds (an icon a tab fetched itself).
    var cached: NSImage?

    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        calls += 1
        guard succeeds else { return nil }
        return Self.icon()
    }

    func cachedFavicon(at url: URL, profile: BrowserProfileID) -> NSImage? { cached }

    static func icon() -> NSImage? {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 1, height: 1)) }
    }

    func until(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < deadline { await Task.yield() }
    }
}
