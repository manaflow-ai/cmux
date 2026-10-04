import Foundation
import Testing
@testable import CmuxNextApps

/// FIRST-PARTY-APPS (Lawrence): first-party apps are hide-only, CodeRouter
/// ships hidden, and the App Store never lists itself.
@MainActor
@Suite struct AppFirstPartyPolicyTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-app-firstparty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func registry(_ root: URL) async -> AppRegistry {
        let registry = AppRegistry(directory: root, bundledRoot: root.appending(path: "no-samples"))
        await registry.load()
        return registry
    }

    @Test func codeRouterShipsInstalledButHidden() async throws {
        let app = try #require(await registry(try scratch()).app("cmux/coderouter"))
        #expect(app.isInstalled && app.isHidden && !app.isVisible)
    }

    @Test func firstPartyAppsCannotBeRemovedOnlyHidden() async throws {
        let registry = await registry(try scratch())
        await #expect(throws: AppRegistryError.firstPartyHideOnly("cmux/home")) { try await registry.remove("cmux/home") }
        #expect(registry.app("cmux/home")?.isInstalled == true)
        try await registry.setHidden("cmux/home", true)
        #expect(registry.app("cmux/home")?.isHidden == true)
    }

    /// A record from the earlier removable behavior (installed=false) reads
    /// as installed and hidden.
    @Test func aRemovedFirstPartyRecordMigratesToHidden() async throws {
        let root = try scratch()
        try AppRegistryFile(apps: ["cmux/home": .init(installed: false, enabled: true)]).save(to: root.appending(path: "registry.json"))
        let home = try #require(await registry(root).app("cmux/home"))
        #expect(home.isInstalled && home.isHidden)
    }

    @Test func theAppStoreNeverListsItself() async throws {
        let bundles = await registry(try scratch()).apps.map(\.bundle)
        #expect(bundles.contains { $0.id == "cmux/app-store" })
        let listings = try await BundledAppStoreCatalog(bundles: bundles).search(query: "", category: nil)
        #expect(!listings.contains { $0.id == "cmux/app-store" })
        #expect(listings.contains { $0.id == "cmux/home" })
    }
}
