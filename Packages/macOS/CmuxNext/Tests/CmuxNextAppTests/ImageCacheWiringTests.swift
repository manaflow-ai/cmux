import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextMemory
import Foundation
import Testing

/// The app wires its picture caches to the memory coordinator only with `memoryImageCaches` on, and a
/// page thumbnail the cache cannot keep is never captured.
@MainActor @Suite(.serialized)
struct ImageCacheWiringTests {
    private static let imageCacheNames: Set<String> = [
        AppMemoryConsumers.previewImagesName, AppMemoryConsumers.pageThumbnailsName,
        AppMemoryConsumers.internalPagePicturesName, HibernationSnapshots.memoryConsumerName,
    ]

    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: names))
        return services
    }

    /// The image cache consumers registered with `services`' coordinator now.
    private static func registered(_ services: AppServices) -> Set<String> {
        let rows = services.memoryCoordinator.report(budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)).consumers
        return Set(rows.map(\.name)).intersection(imageCacheNames)
    }

    @Test func thePictureCachesRegisterOnlyWithTheFeature() {
        let off = Self.services()
        let offHibernation = BrowserHibernation(cache: off.cache, memory: off.memoryCoordinator, deadlines: off.mainDeadlines)
        AppMemoryConsumers(services: off).registerImageCaches()
        AppMemoryConsumers(services: off).registerHibernationSnapshots(offHibernation)
        #expect(Self.registered(off).isEmpty, "\(Self.registered(off).sorted()) registered with memoryImageCaches off")

        let on = Self.services(enabling: [Feature.memoryImageCaches.name])
        let onHibernation = BrowserHibernation(cache: on.cache, memory: on.memoryCoordinator, deadlines: on.mainDeadlines)
        AppMemoryConsumers(services: on).registerImageCaches()
        AppMemoryConsumers(services: on).registerHibernationSnapshots(onHibernation)
        #expect(Self.registered(on) == Self.imageCacheNames)
        withExtendedLifetime((offHibernation, onHibernation)) {}
    }

    /// At the critical limit the thumbnails keep nothing, so a hover on a shown page must not start a
    /// main-thread engine capture each time: it shows its fallback instead. At the default limit it captures.
    @Test func aHoverCapturesNoPageThumbnailAtTheCriticalLimit() async throws {
        let services = Self.services()
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let key = tab.id.rawValue
        _ = services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        services.cache.shownPages.insert(key)
        try #require(tab.state.phase == .finished)
        let size = CGSize(width: 320, height: 200)

        services.cache.pageThumbnails.updateMemoryLimit(.criticalThreshold)
        #expect(!services.cache.keepsPageThumbnails)
        for _ in 0..<2 { _ = await services.cache.previewImage(for: key, maxPixelSize: size) }
        #expect(tab.thumbnailCount == 0, "\(tab.thumbnailCount) hovers captured a thumbnail the cache drops")

        services.cache.pageThumbnails.updateMemoryLimit(.default)
        _ = await services.cache.previewImage(for: key, maxPixelSize: size)
        #expect(tab.thumbnailCount == 1, "a hover at the default limit did not picture the shown page")
    }
}
