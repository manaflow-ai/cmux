import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// p07-memory-056: the app caches of the first CmuxNextApp batch are memory consumers (or carry a
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

    // MARK: Icon assets (lossless)

    private static func icon(_ index: Int) -> String {
        "svg:sha256-" + String(format: "%064x", index)
    }

    private static func storedIcons(_ count: Int) throws -> IconAssetImages {
        let images = IconAssetImages()
        for index in 0..<count {
            images.store(SidebarFavicon(try image()), for: icon(index))
        }
        return images
    }

    @Test func iconAssetsReportTheirPixelBytes() throws {
        let images = try Self.storedIcons(3)
        #expect(images.memoryUsage == MemoryUsage(footprintBytes: 3 * 8 * 8 * 4, entries: 3))
        #expect(images.image(Self.icon(1), owner: nil) != nil)
    }

    @Test func aNewLimitFreesNoIconAsset() throws {
        let images = try Self.storedIcons(3)
        images.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(images.memoryUsage?.entries == 3)
    }

    @Test func aCriticalReleaseDropsEveryIconAssetAndAReadStoresItAgain() throws {
        let images = try Self.storedIcons(3)
        #expect(images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(images.memoryUsage == .empty)
        #expect(images.image(Self.icon(0), owner: nil) == nil, "a released asset is read again from its owner")
        images.store(SidebarFavicon(try Self.image()), for: Self.icon(0))
        #expect(images.image(Self.icon(0), owner: nil) != nil, "the read lands as before")
        #expect(images.memoryUsage?.entries == 1)
    }

    @Test func iconAssetsKeepAtMostKeepOldestDroppedFirst() throws {
        let images = try Self.storedIcons(IconAssetImages.keep + 1)
        #expect(images.memoryUsage?.entries == IconAssetImages.keep)
        #expect(images.image(Self.icon(0), owner: nil) == nil, "the oldest decode went")
        #expect(images.image(Self.icon(IconAssetImages.keep), owner: nil) != nil)
    }

    @Test func aPartialIconReleaseStopsWhenTheSliceIsSpent() throws {
        let images = try Self.storedIcons(3)
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
