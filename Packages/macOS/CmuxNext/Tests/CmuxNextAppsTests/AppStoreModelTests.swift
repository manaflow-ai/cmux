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
        model.show(.installed)
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

    /// Page history (history.md 4.2b): tabs, searches and opened listings
    /// are navigations that Back and Forward walk like a browser tab's.
    @Test func backAndForwardWalkTabsSearchesAndListings() async throws {
        let model = try await model()
        var navigations = 0
        model.onNavigate = { navigations += 1 }
        #expect(!model.canGoBack && !model.canGoForward)
        model.query = "pull"
        model.show(.discover, selection: "cmux/github-prs")
        model.show(.installed)
        #expect(navigations == 2)
        #expect(model.goBack())
        #expect(model.tab == .discover && model.selection == "cmux/github-prs")
        #expect(model.goBack())
        #expect(model.selection == nil && model.query == "pull")
        #expect(!model.canGoBack && !model.goBack())
        #expect(model.goForward())
        #expect(model.selection == "cmux/github-prs")
        model.open(appID: "cmux/agent-status")
        #expect(!model.canGoForward)
        #expect(model.goBack())
        #expect(model.selection == "cmux/github-prs")
        #expect(navigations == 7)
    }

    @Test func showingTheSameLocationIsNotANavigation() async throws {
        let model = try await model()
        model.show(.discover)
        model.open(appID: "cmux/github-prs")
        model.open(appID: "cmux/github-prs")
        #expect(model.backList.count == 1)
    }

    @Test func removeIsUndoneWithoutAConfirmation() async throws {
        let model = try await model()
        try await model.install("cmux/github-prs")
        await model.requestRemove("cmux/github-prs")
        #expect(model.pendingRemoval == "cmux/github-prs")
        #expect(model.state(of: "cmux/github-prs")?.isEnabled == false)
        #expect(model.state(of: "cmux/github-prs")?.isInstalled == true)
        await model.undoRemove()
        #expect(model.pendingRemoval == nil)
        #expect(model.state(of: "cmux/github-prs")?.isActive == true)
    }

    @Test func aPendingRemoveCommitsAfterItsUndoWindow() async throws {
        let model = try await model()
        var removed: [String] = []
        model.onRemoved = { removed.append($0) }
        model.removalUndoInterval = .zero
        try await model.install("cmux/github-prs")
        await model.requestRemove("cmux/github-prs")
        #expect(await eventually { await MainActor.run { model.state(of: "cmux/github-prs")?.isInstalled == false } })
        #expect(removed == ["cmux/github-prs"])
        #expect(model.pendingRemoval == nil)
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
