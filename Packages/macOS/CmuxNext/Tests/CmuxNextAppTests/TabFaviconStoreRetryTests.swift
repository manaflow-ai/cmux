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

    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        calls += 1
        guard succeeds else { return nil }
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
