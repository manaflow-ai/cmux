import Foundation
import Testing
@testable import CmuxNextApps

/// The shipped first-party apps carry manifest v2 `presentation` (app-screens.md 4,
/// app-platform.md 16): Home, App Store and CodeRouter resolve in the registry
/// with the same fields as any app, so the sidebar builds its top band from them.
@MainActor
@Suite struct AppPresentationTests {
    private func registry() async throws -> AppRegistry {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-app-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AppRegistry(directory: root, bundledRoot: root.appending(path: "no-samples"))
        await registry.load()
        return registry
    }

    @Test func homeResolvesWithTheAppColumnScreen() async throws {
        let home = try #require(try await registry().app("cmux/home"))
        #expect(home.manifest.raw["presentation"]?["screen"]?.stringValue == "appColumn")
        #expect(home.isInstalled)
    }

    @Test func appStoreAndCodeRouterResolveWithTheAppScreen() async throws {
        let registry = try await registry()
        for id in ["cmux/app-store", "cmux/coderouter"] {
            let app = try #require(registry.app(id), "\(id)")
            #expect(app.manifest.raw["presentation"]?["screen"]?.stringValue == "app", "\(id)")
        }
    }
}
