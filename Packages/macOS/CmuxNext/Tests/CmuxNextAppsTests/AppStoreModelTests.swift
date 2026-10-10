import Foundation
import Testing
@testable import CmuxNextApps

/// The App Store model over the bundled catalog.
struct AppStoreModelTests {
    private func model() async throws -> AppStoreModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-apps-store-\(UUID().uuidString)")
        let registry = AppRegistry(directory: root, firstPartyRoot: root.appending(path: "no-first-party"))
        await registry.load()
        let model = AppStoreModel(catalog: RegistryAppStoreCatalog(registry: registry), registry: registry,
                                  host: AppHost(sink: AppPreviewSink(), clock: ManualAppClock()),
                                  previewHost: AppHost(sink: AppPreviewSink(), clock: ManualAppClock()))
        model.refresh()
        #expect(await eventually { await MainActor.run { model.listings.count == 3 } })
        return model
    }

    @Test func bundledCatalogListsTheSamplesAsFirstParty() async throws {
        let model = try await model()
        #expect(Set(model.listings.map(\.id)) == ["cmux/github-prs", "cmux/running-agents", "cmux/agent-status"])
        #expect(model.listings.allSatisfy { $0.tier == .firstParty && $0.publisherVerified })
        #expect(model.allCategories == ["agents", "git", "monitoring", "sidebar"])
    }

    @Test func searchAndCategoryFilter() async throws {
        let model = try await model()
        model.query = "pull"
        #expect(await eventually { await MainActor.run { model.listings.map(\.id) == ["cmux/github-prs"] } })
        model.query = ""
        model.category = "monitoring"
        #expect(await eventually { await MainActor.run { model.listings.map(\.id) == ["cmux/agent-status"] } })
        #expect(model.allCategories.count == 4)
    }

    @Test func openingAListingClearsFiltersThatHideIt() async throws {
        let model = try await model()
        model.category = "git"
        #expect(await eventually { await MainActor.run { model.listings.count == 1 } })
        model.tab = .installed
        model.open(appID: "cmux/agent-status")
        #expect(model.tab == .discover)
        #expect(model.category == nil)
        #expect(await eventually { await MainActor.run { model.selectedListing?.id == "cmux/agent-status" } })
    }

    @Test func removeAndInstallRoundTripAndNotify() async throws {
        let model = try await model()
        var removed: [String] = []
        try await model.install("cmux/github-prs") // samples are opt-in
        model.onRemoved = { removed.append($0) }
        try await model.remove("cmux/github-prs")
        #expect(model.state(of: "cmux/github-prs")?.isInstalled == false)
        #expect(!model.installedApps.contains { $0.id == "cmux/github-prs" })
        #expect(removed == ["cmux/github-prs"])
        try await model.install("cmux/github-prs")
        #expect(model.state(of: "cmux/github-prs")?.isActive == true)
    }

    /// Opening the store does no disk I/O: the catalog lists what the registry's launch scan found, nothing before it.
    @Test func catalogReadsTheRegistryScanAndNeverScansItself() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-apps-store-\(UUID().uuidString)")
        let registry = AppRegistry(directory: root, firstPartyRoot: root.appending(path: "no-first-party"))
        let catalog = RegistryAppStoreCatalog(registry: registry)
        #expect(try await catalog.search(query: "", category: nil).isEmpty)
        await registry.load()
        #expect(try await catalog.search(query: "", category: nil).count == 3)
    }
}
