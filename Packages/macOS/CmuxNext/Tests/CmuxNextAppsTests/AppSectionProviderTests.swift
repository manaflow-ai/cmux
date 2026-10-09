import AppKit
import Foundation
import Testing
@testable import CmuxNextApps

/// Sidebar app sections over the client: mounts end with the window's
/// sections, and before the supervisor's list a section says why it is empty.
@MainActor
struct AppSectionProviderTests {
    @Test func releaseAllEndsEveryMountOnTheSupervisor() async throws {
        let (client, transport) = await TestClient.make()
        let provider = AppSectionProvider(client: client)
        let contribution = "cmux/github-prs#prs"
        try await client.install("cmux/github-prs")
        #expect(provider.makeView(for: contribution) != nil)
        #expect(await eventually { await MainActor.run { transport.mounted.count == 1 } })
        provider.releaseAll()
        #expect(await eventually { await MainActor.run { transport.mounted.isEmpty } })
    }

    /// An older daemon (no apps-v1): the section shows the reason, not
    /// "not installed", and renders once a supervisor answers.
    @Test func beforeTheListASectionShowsWhyItIsEmpty() async throws {
        let transport = FakeAppsTransport(available: false)
        let client = AppsClient(transport: transport)
        client.start()
        let provider = AppSectionProvider(client: client)
        // A layout saved with CodeRouter's v1 section id; its v2 manifest has one section.
        let contribution = "cmux/coderouter#coderouter"
        #expect(provider.title(for: contribution) == "cmux/coderouter")
        #expect(provider.makeView(for: contribution) != nil)
        #expect(transport.mounted.isEmpty)
        transport.setAvailable(true)
        #expect(await eventually { await MainActor.run { !transport.mounted.isEmpty } })
        #expect(await eventually { await MainActor.run { provider.title(for: contribution) == "CodeRouter" } })
    }
}
