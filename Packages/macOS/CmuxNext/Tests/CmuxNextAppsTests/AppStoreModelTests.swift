import Foundation
import Testing
@testable import CmuxNextApps

/// The App Store model over the apps client (a fake supervisor with the
/// bundled first-party apps and samples).
@MainActor
struct AppStoreModelTests {
    private func model() async -> (AppStoreModel, FakeAppsTransport) {
        let (client, transport) = await TestClient.make()
        return (AppStoreModel(client: client), transport)
    }

    @Test func listsEveryAvailableAppButTheStoreItself() async {
        let (model, transport) = await model()
        let expected = Set(transport.records.map(\.id)).subtracting([AppStoreListing.storeID])
        #expect(Set(model.listings.map(\.id)) == expected)
        #expect(model.listings.contains { $0.id == "cmux/github-prs" && $0.tier == .firstParty && $0.publisherVerified })
        #expect(model.allCategories == Set(model.listings.flatMap(\.categories)).sorted())
    }

    @Test func searchAndCategoryFilter() async {
        let (model, _) = await model()
        model.query = "pull"
        #expect(model.listings.map(\.id) == ["cmux/github-prs"])
        model.query = ""
        model.category = "monitoring"
        #expect(model.listings.map(\.id).contains("cmux/agent-status"))
        #expect(model.listings.allSatisfy { $0.categories.contains("monitoring") })
    }

    @Test func openingAListingClearsFiltersThatHideIt() async {
        let (model, _) = await model()
        model.category = "git"
        model.show(.installed)
        model.open(appID: "cmux/agent-status")
        #expect(model.tab == .discover)
        #expect(model.category == nil)
        #expect(model.selectedListing?.id == "cmux/agent-status")
    }

    @Test func removeAndInstallRoundTrip() async throws {
        let (model, _) = await model()
        try await model.install("cmux/github-prs") // samples are opt-in
        #expect(model.state(of: "cmux/github-prs")?.isActive == true)
        try await model.remove("cmux/github-prs")
        #expect(model.state(of: "cmux/github-prs")?.installed == false)
        #expect(!model.installedApps.contains { $0.id == "cmux/github-prs" })
    }

    /// Page history (history.md 4.2b): tabs, searches and opened listings
    /// are navigations that Back and Forward walk like a browser tab's.
    @Test func backAndForwardWalkTabsSearchesAndListings() async {
        let (model, _) = await model()
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

    @Test func showingTheSameLocationIsNotANavigation() async {
        let (model, _) = await model()
        model.show(.discover)
        model.open(appID: "cmux/github-prs")
        model.open(appID: "cmux/github-prs")
        #expect(model.backList.count == 1)
    }

    @Test func removeIsUndoneWithoutAConfirmation() async throws {
        let (model, _) = await model()
        try await model.install("cmux/github-prs")
        await model.requestRemove("cmux/github-prs")
        #expect(model.pendingRemoval == "cmux/github-prs")
        #expect(model.state(of: "cmux/github-prs")?.enabled == false)
        #expect(model.state(of: "cmux/github-prs")?.installed == true)
        await model.undoRemove()
        #expect(model.pendingRemoval == nil)
        #expect(model.state(of: "cmux/github-prs")?.isActive == true)
    }

    @Test func aPendingRemoveCommitsAfterItsUndoWindow() async throws {
        let (model, transport) = await model()
        model.removalUndoInterval = .zero
        try await model.install("cmux/github-prs")
        await model.requestRemove("cmux/github-prs")
        #expect(await eventually { await MainActor.run { model.state(of: "cmux/github-prs")?.installed == false } })
        #expect(transport.records.first { $0.id == "cmux/github-prs" }?.installed == false)
        #expect(model.pendingRemoval == nil)
    }

    /// While the supervisor is unreachable nothing can change and the store says why.
    @Test func nothingChangesWhileTheSupervisorIsUnreachable() async {
        let (model, transport) = await model()
        transport.setAvailable(false)
        #expect(!model.canChange)
        #expect(model.client.unavailableReason == .notConnected)
        await #expect(throws: AppsClientError.unavailable(.notConnected)) { try await model.install("cmux/github-prs") }
    }
}
