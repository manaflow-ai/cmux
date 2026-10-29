import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The app caches of the first CmuxNextApp batch are memory consumers (or carry a
/// `memory: fixed` proof). For each consumer a new limit frees nothing, a release at limit 0 leaves 0
/// entries and 0 bytes, nothing is kept while the limit is 0, and a hit after a release recomputes
/// (or, for the lossy saved frames, shows nothing).
@MainActor @Suite struct AppCacheMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        private(set) var names: [String] = []

        init(limit: MemoryLimit = .default) {
            self.limit = limit
        }

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            names.append(entry.name)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    /// Records every URL a museum search fetches.
    private actor FetchLog {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
        func count(host: String) -> Int { urls.filter { $0.host == host }.count }
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    /// One `side` x `side` RGBA image: `side * side * 4` bytes.
    private static func image(side: Int = 8) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    // MARK: Agent pane saved frames (lossy)

    private static let frameSize = NSSize(width: 4, height: 4)

    private static func heldFrames(_ count: Int) async throws -> AgentPaneLaunchImages {
        let images = AgentPaneLaunchImages(directory: nil)
        for index in 0..<count {
            await images.hold("tab_\(index)", try image(), size: frameSize, appearance: nil)
        }
        return images
    }

    @Test func savedFramesAreALossyConsumerOnlyCriticalPressureActsOn() {
        let traits = AgentPaneLaunchImages.memoryTraits
        #expect(traits.retention == .lossy)
        #expect(traits.dataAccess == .none)
        #expect(traits.isManaged)
    }

    @Test func savedFramesReportTheirEncodedBytes() async throws {
        let images = try await Self.heldFrames(3)
        let usage = try #require(images.memoryUsage)
        #expect(usage.entries == 3)
        #expect(usage.footprintBytes > 0)
        _ = images.take("tab_0")
        let after = try #require(images.memoryUsage)
        #expect(after.entries == 2)
        #expect(after.footprintBytes < usage.footprintBytes, "a taken frame leaves the count")
    }

    @Test func aNewLimitFreesNoSavedFrame() async throws {
        let images = try await Self.heldFrames(3)
        images.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(images.memoryUsage?.entries == 3)
    }

    @Test func aCriticalReleaseDropsEverySavedFrameAndKeepsNoNewOne() async throws {
        let images = try await Self.heldFrames(3)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == .empty)
        #expect(images.take("tab_1") == nil, "a released frame is gone: the pane shows its loading state")
        await images.hold("tab_9", try Self.image(), size: Self.frameSize, appearance: nil)
        #expect(images.memoryUsage == .empty, "at the critical limit no frame is kept")
    }

    @Test func aPartialReleaseKeepsTheNewestSavedFrames() async throws {
        let images = try await Self.heldFrames(4)
        // 4 % of the 64 frames it keeps at most is 2.
        #expect(images.releaseMemory(within: Self.slice(4)) == .done)
        #expect(images.memoryUsage?.entries == 2)
        #expect(images.take("tab_0") == nil && images.take("tab_1") == nil, "the oldest go first")
        #expect(images.take("tab_3") != nil)
    }

    @Test func aSpentSliceAsksForAnotherTurn() async throws {
        let images = try await Self.heldFrames(2)
        #expect(images.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(images.memoryUsage?.entries == 2)
    }

    @Test func registeringUnderCriticalPressureKeepsNoSavedFrame() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        let registry = FakeRegistry(limit: MemoryLimit(percent: 0))
        images.registerMemoryConsumer(with: registry)
        #expect(registry.names == [AgentPaneLaunchImages.memoryConsumerName])
        await images.hold("tab_0", try Self.image(), size: Self.frameSize, appearance: nil)
        #expect(images.memoryUsage == .empty)
    }

    // MARK: Agent pane launch read (lossy)

    /// The launch read's decoded pages are counted, and a release at the full limit keeps them.
    @Test func theLaunchReadIsCountedAndAFullLimitReleaseKeepsIt() async throws {
        let directory = try await AgentPaneLaunchImageReadTests.saved(["tab_a", "tab_b"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = AgentPaneLaunchImages(directory: directory, clock: ManualClock())
        await images.prefetch(on: AgentPaneLaunchImageReadTests.work)?.value
        let usage = try #require(images.memoryUsage)
        #expect(usage.entries == 2)
        #expect(images.releaseMemory(within: Self.slice(100)) == .done)
        #expect(images.memoryUsage == usage, "the full limit keeps the read")
        for key in ["tab_a", "tab_b"] {
            #expect(images.take(key) != nil, "a page kept at the full limit is handed out")
        }
        // The same decode as the launch read's, off the main thread as there.
        let pageBytes = await Task.detached {
            ["tab_a", "tab_b"].compactMap { key in
                LaunchFileReader().image(at: directory.appending(path: "\(key)@2x.jpg"), maximumBytes: 8 << 20)
            }.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        }.value
        #expect(pageBytes > 0)
        #expect(usage.footprintBytes == pageBytes, "the read counts its decoded pages' bytes")
    }

    /// Below the full limit the read's pages go at once, with the deadline that would have dropped them.
    @Test(.timeLimit(.minutes(1))) func aReleaseBelowTheFullLimitDropsTheLaunchReadAndItsDeadline() async throws {
        let directory = try await AgentPaneLaunchImageReadTests.saved(["tab_a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualClock()
        let images = AgentPaneLaunchImages(directory: directory, clock: clock)
        await images.prefetch(on: AgentPaneLaunchImageReadTests.work)?.value
        try await clock.waitForSleeper()
        #expect(images.memoryUsage?.entries == 1)
        #expect(images.releaseMemory(within: Self.slice(99)) == .done)
        #expect(images.memoryUsage == .empty)
        #expect(images.take("tab_a") == nil, "a released page is gone: the pane shows its loading state")
        #expect(clock.sleeperCount == 0, "the drop deadline went with the read")
        #expect(images.prefetch(on: AgentPaneLaunchImageReadTests.work) == nil, "a released read is not read again")
    }

    // MARK: Icon assets (lossless)

    private nonisolated static let svg = Data(
        ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#2a2"></path></svg>"##.utf8)

    /// Counts the owner's `get-blob` reads.
    private actor BlobLog {
        private(set) var reads = 0
        func record() { reads += 1 }
    }

    private static func icon(_ index: Int) -> String {
        "svg:sha256-" + String(format: "%064x", index)
    }

    private static func storedIcons(_ count: Int, clock: ManualClock = ManualClock()) throws -> IconAssetImages {
        let images = IconAssetImages(clock: clock)
        for index in 0..<count {
            images.store(SidebarFavicon(try image()), for: icon(index))
        }
        return images
    }

    /// A source that serves ``svg`` for every asset and logs each read.
    private static func source(_ log: BlobLog) -> IconAssetImages.Source {
        let svg = svg
        return IconAssetImages.Source { _ in
            await log.record()
            return (svg, "image/svg+xml")
        }
    }

    /// Reads `icon` (not decoded yet) as an observing mapping does, then what that reader reads again once
    /// it is told the icon arrived.
    private static func arrived(_ icon: String, in images: IconAssetImages, from source: IconAssetImages.Source) async -> SidebarFavicon? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = images.image(icon, from: source)
            } onChange: {
                continuation.resume()
            }
        }
        return images.image(icon, from: source)
    }

    @Test func iconAssetsReportTheirPixelBytes() throws {
        let images = try Self.storedIcons(3)
        #expect(images.memoryUsage == MemoryUsage(footprintBytes: 3 * 8 * 8 * 4, entries: 3))
        #expect(images.image(Self.icon(1), from: nil) != nil)
    }

    @Test func aNewLimitFreesNoIconAsset() throws {
        let images = try Self.storedIcons(3)
        images.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(images.memoryUsage?.entries == 3)
    }

    @Test func aCriticalReleaseForgetsIdleIconAssetsAndKeepsThoseInUse() throws {
        let clock = ManualClock()
        let images = try Self.storedIcons(3, clock: clock)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done, "only decodes in use are left")
        #expect(images.memoryUsage?.entries == 3, "a decode that just arrived is in use")
        clock.advance(by: IconAssetImages.inUse * 2)
        #expect(images.image(Self.icon(2), from: nil) != nil, "a mapping draws icon 2 now")
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == MemoryUsage(footprintBytes: 8 * 8 * 4, entries: 1))
        #expect(images.image(Self.icon(2), from: nil) != nil, "the decode in use stays")
        #expect(images.image(Self.icon(0), from: nil) == nil, "an idle decode goes")
        clock.advance(by: IconAssetImages.inUse * 2)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == .empty, "once idle, the last decode goes too")
    }

    /// The sidebar and the strips read icons inside their observed mappings: forgetting a decode must not map
    /// them again (they would read nil, blank every custom icon and read them all from their owners again).
    @Test func aReleaseTellsNoReaderOfTheIconsItForgets() throws {
        let clock = ManualClock()
        let images = try Self.storedIcons(2, clock: clock)
        let told = Mutex(false)
        let drawn = withObservationTracking {
            images.image(Self.icon(0), from: nil)
        } onChange: {
            told.withLock { $0 = true }
        }
        #expect(drawn != nil)
        clock.advance(by: IconAssetImages.inUse * 2)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == .empty)
        images.store(SidebarFavicon(try Self.image()), for: Self.icon(1))
        #expect(told.withLock { $0 } == false, "forgetting icon 0, or another icon's arrival, mapped icon 0's reader again")
    }

    @Test(.timeLimit(.minutes(1))) func aForgottenIconIsReadAgainFromItsOwnerOnItsNextRead() async throws {
        let clock = ManualClock()
        let images = IconAssetImages(clock: clock, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let log = BlobLog()
        let source = Self.source(log)
        let icon = Self.icon(7)
        #expect(await Self.arrived(icon, in: images, from: source) != nil, "the first read stores the decode")
        #expect(await log.reads == 1)
        #expect(images.image(icon, from: source) != nil)
        #expect(await log.reads == 1, "a kept decode is not read again")
        clock.advance(by: IconAssetImages.inUse * 2)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == .empty)
        #expect(await Self.arrived(icon, in: images, from: source) != nil, "the next read after the release stores it again")
        #expect(await log.reads == 2, "a forgotten icon is read from its owner again")
        #expect(images.memoryUsage?.entries == 1)
    }

    @Test func iconAssetsKeepAtMostKeepLeastRecentlyUsedDroppedFirst() throws {
        let images = try Self.storedIcons(IconAssetImages.keep)
        #expect(images.image(Self.icon(0), from: nil) != nil, "icon 0 is read again: now the most recently used")
        images.store(SidebarFavicon(try Self.image()), for: Self.icon(IconAssetImages.keep))
        #expect(images.memoryUsage?.entries == IconAssetImages.keep)
        #expect(images.image(Self.icon(1), from: nil) == nil, "the least recently used decode went")
        #expect(images.image(Self.icon(0), from: nil) != nil)
        #expect(images.image(Self.icon(IconAssetImages.keep), from: nil) != nil)
    }

    @Test func aPartialIconReleaseStopsWhenTheSliceIsSpent() throws {
        let clock = ManualClock()
        let images = try Self.storedIcons(3, clock: clock)
        clock.advance(by: IconAssetImages.inUse * 2)
        #expect(images.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(images.memoryUsage?.entries == 3)
    }

    // MARK: Browse more art thumbnails (lossless)

    private nonisolated static let cleveland = """
    {"data": [
      {"id": 1, "title": "Night", "creation_date": "1645", "share_license_status": "CC0",
       "creators": [{"description": "Salvator Rosa (Italian, 1615–1673)"}], "url": "https://clevelandart.org/art/1",
       "images": {"web": {"url": "https://openaccess-cdn.clevelandart.org/1/1_web.jpg"},
                  "print": {"url": "https://openaccess-cdn.clevelandart.org/1/1_print.jpg"}}},
      {"id": 2, "title": "Day", "creation_date": "1650", "share_license_status": "CC0",
       "creators": [{"description": "Salvator Rosa (Italian, 1615–1673)"}], "url": "https://clevelandart.org/art/2",
       "images": {"web": {"url": "https://openaccess-cdn.clevelandart.org/2/2_web.jpg"},
                  "print": {"url": "https://openaccess-cdn.clevelandart.org/2/2_print.jpg"}}}
    ]}
    """
    private nonisolated static let imageHost = "openaccess-cdn.clevelandart.org"

    /// A session over one recorded collection; every image is 1,000 bytes.
    private static func museum(_ log: FetchLog, memory: (any MemoryConsumerRegistry)? = nil) -> MuseumArtSession {
        let search = MuseumArtSearch { url in
            await log.record(url)
            switch url.host {
            case "openaccess-api.clevelandart.org": return Data(cleveland.utf8)
            case imageHost: return Data(repeating: 7, count: 1_000)
            default: throw URLError(.cannotFindHost)
            }
        }
        return MuseumArtSession(search: search, memory: memory)
    }

    /// The session's result keys after one search, with both thumbnails fetched.
    private static func filledMuseum(_ log: FetchLog, memory: (any MemoryConsumerRegistry)? = nil) async throws
        -> (MuseumArtSession, [String]) {
        let session = museum(log, memory: memory)
        let found = try #require(await session.find("rosa")["results"]?.arrayValue, "the search answered no results")
        let keys = found.compactMap { $0["key"]?.stringValue }
        try #require(keys.count == 2)
        for key in keys { #expect(await session.thumbnail(key: key) != nil) }
        return (session, keys)
    }

    @Test func museumThumbnailsAreKeptAndCounted() async throws {
        let log = FetchLog()
        let (session, keys) = try await Self.filledMuseum(log)
        #expect(session.memoryUsage == MemoryUsage(footprintBytes: 2_000, entries: 2))
        _ = await session.thumbnail(key: keys[0])
        #expect(await log.count(host: Self.imageHost) == 2, "a kept thumbnail is not fetched again")
    }

    @Test func aCriticalReleaseDropsMuseumThumbnailsAndAHitFetchesAgain() async throws {
        let log = FetchLog()
        let (session, keys) = try await Self.filledMuseum(log)
        session.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(session.memoryUsage?.entries == 2, "a new limit frees nothing")
        #expect(session.releaseMemory(within: Self.slice(100)) == .done, "the full limit keeps both")
        #expect(session.memoryUsage?.entries == 2)
        #expect(session.releaseMemory(within: Self.slice(0)) == .done)
        #expect(session.memoryUsage == .empty)
        session.updateMemoryLimit(.default)
        #expect(await session.thumbnail(key: keys[1]) != nil, "the result still names its work")
        #expect(await log.count(host: Self.imageHost) == 3, "a hit after the release fetches again")
        #expect(session.memoryUsage?.entries == 1)
    }

    @Test func aMuseumSessionRegisteredUnderCriticalPressureServesButKeepsNoThumbnail() async throws {
        let log = FetchLog()
        let registry = FakeRegistry(limit: MemoryLimit(percent: 0))
        let (session, _) = try await Self.filledMuseum(log, memory: registry)
        #expect(registry.names == [MuseumArtSession.memoryConsumerName])
        #expect(session.memoryUsage == .empty)
    }

    @Test func aSpentSliceLeavesMuseumThumbnailsForTheNextTurn() async throws {
        let (session, _) = try await Self.filledMuseum(FetchLog())
        #expect(session.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(session.memoryUsage?.entries == 2)
    }
}
