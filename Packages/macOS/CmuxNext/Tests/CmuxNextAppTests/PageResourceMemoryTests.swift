@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextPages
import Foundation
import Testing

/// The app's memory consumers of p07-memory-057: the Settings and Apps pages' dynamic resources
/// (``PageResourceDataCache``) and the notification badges (``StatusNotificationImage``). After the
/// critical release a consumer holds 0 entries, and the next request draws again.
@MainActor @Suite struct PageResourceMemoryTests {
    /// Keeps each registered entry and hands it the default limit, as the coordinator does at normal.
    @MainActor final class RecordingRegistry: MemoryConsumerRegistry {
        private(set) var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(.default)
        }
    }

    @MainActor final class Calls {
        var count = 0
    }

    /// The coordinator's critical pass: the limit first, then one release slice.
    private static func pressCritical(_ consumer: any MemoryConsumer) -> MemoryReleaseProgress {
        consumer.updateMemoryLimit(.criticalThreshold)
        return consumer.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false })
    }

    private static func request(_ prefix: String, _ name: String) -> PageResourceRequest {
        PageResourceRequest(prefix: prefix, path: [name], url: URL(string: "cmux-page://cmux.test/\(prefix)/\(name)")!)
    }

    @Test func aSettingsIconIsDrawnAgainAfterTheRelease() async throws {
        let calls = Calls(), registry = RecordingRegistry()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let source = SettingsBackdropThumbnails(choices: [], userImages: nil, iconPNG: { _ in
            calls.count += 1
            return png
        }, memory: registry)
        let entry = try #require(registry.entries.first)
        #expect(entry.name == "settings-backdrop-thumbnails")
        let consumer = try #require(entry.liveConsumer)
        let request = Self.request(SettingsIconAssets.prefix, "icon")

        #expect(await source.resource(for: request)?.data == png)
        #expect(await source.resource(for: request)?.data == png)
        #expect(calls.count == 1, "the second request is a hit")
        #expect(source.cache.count == 1)

        #expect(Self.pressCritical(consumer) == .done)
        #expect(source.cache.count == 0)
        #expect(await source.resource(for: request)?.data == png)
        #expect(calls.count == 2, "a request after the release draws again")
    }

    @Test func anAppsGlyphIsDrawnAgainAfterTheRelease() async throws {
        let registry = RecordingRegistry()
        let glyphs = AppsGlyphResource(memory: registry)
        let entry = try #require(registry.entries.first)
        #expect(entry.name == "apps-glyphs")
        let consumer = try #require(entry.liveConsumer)
        let request = Self.request(AppsGlyphResource.prefix, "cloud")

        let first = try #require(await glyphs.resource(for: request))
        #expect(glyphs.cache.count == 1)
        #expect(Self.pressCritical(consumer) == .done)
        #expect(glyphs.cache.count == 0)
        #expect(await glyphs.resource(for: request)?.data == first.data, "the release only means a new draw")
    }

    @Test func statusBadgesKeepOneLookOnly() {
        let calls = Calls()
        let badge = Data([1, 2, 3])
        let draw = { () -> Data? in
            calls.count += 1
            return badge
        }
        let reasons = ProgramStatusNotification.Reason.allCases
        for reason in reasons {
            #expect(StatusNotificationImage.data(reason, look: "test-look-a", draw: draw) == badge)
        }
        #expect(StatusNotificationImage.cachedCount == reasons.count)
        #expect(StatusNotificationImage.data(.done, look: "test-look-a", draw: draw) == badge)
        #expect(calls.count == reasons.count, "a hit draws nothing")

        #expect(StatusNotificationImage.data(.done, look: "test-look-b", draw: draw) == badge)
        #expect(StatusNotificationImage.cachedCount == 1, "a new icon set or theme empties the badges of the old one")
    }
}
