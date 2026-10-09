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

        func warmScopeTable() { calls.withLock { $0.append(("scopes", Thread.isMainThread)) } }
    }

    @Test func preloadFromTheMainActorRunsTheLoaderOffIt() async {
        let loader = RecordingLoader()
        await AppPlatformResources.preload(using: loader)
        let calls = loader.calls.withLock { $0 }
        #expect(calls.map(\.name) == ["scopes", "samples"])
        #expect(calls.allSatisfy { !$0.onMain })
        #expect(AppBundleLocator.directory(for: "test/recorded")?.path == "/tmp/recorded")
    }

    @Test func theStoreOpensFromTheMirrorWithoutTheLoader() async throws {
        let (client, _) = await TestClient.make()
        let loader = RecordingLoader()
        // No preload: building and showing the store must not need one.
        let pages = AppStorePages { AppStoreModel(client: client) }
        _ = pages.makeView(for: "a")
        pages.present("a", appID: "cmux/github-prs", installed: false)
        let model = try #require(pages.model(for: "a"))
        #expect(model.selectedListing?.id == "cmux/github-prs")
        #expect(!model.listings.isEmpty)
        #expect(AppBundleLocator.directory(for: "never/loaded") == nil)
        #expect(loader.calls.withLock { $0.isEmpty })
    }
}
