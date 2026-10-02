import Foundation
import Testing
@testable import CmuxNextApps

/// The App Store model over the client: listings from the supervisor,
/// search and categories, the Installed tab, defaults.
@MainActor
struct AppStoreModelTests {
    @Test func listingsComeFromTheSupervisor() async throws {
        let (client, _) = await TestClient.make()
        let model = AppStoreModel(client: client)
        #expect(Set(model.listings.map(\.id)) == ["cmux/github-prs", "cmux/running-agents", "cmux/agent-status"])
        #expect(model.listings.allSatisfy { $0.tier == .firstParty && $0.publisherVerified })
        #expect(model.allCategories == Set(client.apps.flatMap(\.manifest.categories)).sorted())
        #expect(Set(["agents", "git", "monitoring", "sidebar"]).isSubset(of: model.allCategories))
        #expect(model.installedApps.map(\.id) == ["cmux/agent-status"])
        #expect(model.state(of: "cmux/agent-status")?.isDefault == true)
    }

    @Test func searchAndCategoryFilter() async throws {
        let (client, _) = await TestClient.make()
        let model = AppStoreModel(client: client)
        model.query = "pull"
        #expect(model.listings.map(\.id) == ["cmux/github-prs"])
        model.query = ""
        model.category = "monitoring"
        #expect(model.listings.map(\.id) == ["cmux/agent-status"])
        #expect(model.allCategories.contains("git"))
    }

    @Test func openingAListingClearsFiltersThatHideIt() async throws {
        let (client, _) = await TestClient.make()
        let model = AppStoreModel(client: client)
        model.category = "git"
        model.tab = .installed
        model.open(appID: "cmux/agent-status")
        #expect(model.tab == .discover)
        #expect(model.category == nil)
        #expect(model.selectedListing?.id == "cmux/agent-status")
    }

    @Test func installRemoveAndHideRoundTrip() async throws {
        let (client, _) = await TestClient.make()
        let model = AppStoreModel(client: client)
        try await model.install("cmux/github-prs")
        #expect(model.installedApps.contains { $0.id == "cmux/github-prs" })
        try await model.setHidden("cmux/github-prs", true)
        #expect(model.state(of: "cmux/github-prs")?.hidden == true)
        try await model.remove("cmux/github-prs")
        #expect(!model.installedApps.contains { $0.id == "cmux/github-prs" })
        #expect(model.state(of: "cmux/github-prs")?.hidden == false)
    }

    @Test func revokingAGrantOfADefaultAppSticks() async throws {
        let (client, _) = await TestClient.make()
        let model = AppStoreModel(client: client)
        let scope = try #require(model.state(of: "cmux/agent-status")?.manifest.scopes.first?.scope)
        #expect(model.state(of: "cmux/agent-status")?.isGranted(scope) == true)
        try await model.setGranted("cmux/agent-status", scope: scope, false)
        #expect(model.state(of: "cmux/agent-status")?.isGranted(scope) == false)
    }

    @Test func disconnectedDisablesChanges() async {
        let (client, _) = await TestClient.make(available: false)
        let model = AppStoreModel(client: client)
        #expect(!model.canChange)
        #expect(model.listings.isEmpty)
    }
}
