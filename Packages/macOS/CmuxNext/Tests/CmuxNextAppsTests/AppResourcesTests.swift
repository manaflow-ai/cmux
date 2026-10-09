import Foundation
import Synchronization
import Testing
@testable import CmuxNextApps

/// The store path never reads the disk on the main actor (architecture.md
/// 5a): resources load once through `AppPlatformResources.preload`, off the
/// main actor, and the store renders from the client mirror.
@MainActor
struct AppResourcesTests {
    /// Records each loader call and whether it ran on the main thread.
    nonisolated final class RecordingLoader: AppResourceLoading {
        let calls = Mutex<[(name: String, onMain: Bool)]>([])
        func sampleDirectories() -> [String: URL] {
            calls.withLock { $0.append(("samples", Thread.isMainThread)) }
            return ["test/recorded": URL(fileURLWithPath: "/tmp/recorded", isDirectory: true)]
        }
    }

    @Test func preloadFromTheMainActorRunsTheLoaderOffIt() async {
        let loader = RecordingLoader()
        await AppPlatformResources.preload(using: loader)
        let calls = loader.calls.withLock { $0 }
        #expect(calls.map(\.name) == ["samples"])
        #expect(calls.allSatisfy { !$0.onMain })
        #expect(AppBundleLocator.directory(for: "test/recorded")?.path == "/tmp/recorded")
    }

    /// The store builds its listings from the mirror alone: icons come from
    /// the supervisor's `bundle_dir`, and no bundled-resource lookup runs.
    @Test func theStoreOpensFromTheMirrorAlone() async throws {
        let manifest = try #require(AppManifest(json: ["id": "test/mirror-only", "name": "Mirror", "version": "1.0.0"]))
        var record = AppRecord(manifest: manifest, tier: .unverified, installed: false, source: .user)
        record.bundleDirectory = URL(fileURLWithPath: "/tmp/supervisor-bundle", isDirectory: true)
        let client = AppsClient(transport: FakeAppsTransport(records: [record]))
        client.start()
        #expect(await eventually { await MainActor.run { client.app("test/mirror-only") != nil } })
        #expect(AppBundleLocator.directory(for: "test/mirror-only") == nil, "nothing preloaded this app")
        let pages = AppStorePages { AppStoreModel(client: client) }
        _ = pages.makeView(for: "a")
        pages.present("a", appID: "test/mirror-only", installed: false)
        let listing = try #require(pages.model(for: "a")?.selectedListing)
        #expect(listing.bundleDirectory?.path == "/tmp/supervisor-bundle")
    }
}
