import CmuxNextApps
import Testing
@testable import CmuxNextApp

/// One presence value from the apps client mirror: hiding an app removes it
/// from every surface that reads presence, unhiding restores it.
@MainActor
struct AppPresenceTests {
    private func client() async -> (AppsClient, FakeAppsTransport) {
        let transport = FakeAppsTransport()
        let client = AppsClient(transport: transport)
        client.start()
        for _ in 0..<400 where client.apps.isEmpty { await Task.yield() }
        return (client, transport)
    }

    @Test func hideRemovesAnAppFromEverySurfaceAndUnhideRestoresIt() async throws {
        let (client, _) = await client()
        try await client.install("cmux/github-prs")
        let section = try #require(client.app("cmux/github-prs")?.manifest.sections.first)
        let contribution = "cmux/github-prs#\(section.id)"
        let sections = AppSectionProvider(client: client) { AppPresence(client.apps).isPresented($0) }

        #expect(AppPresence(client.apps).presented.contains("cmux/github-prs"))
        #expect(SidebarBridge.appInfo("cmux/github-prs", client: client).isHidden == false)
        #expect(sections.title(for: contribution) != nil)

        try await client.set("cmux/github-prs", .hide(true), origin: .mcp)
        let hidden = AppPresence(client.apps)
        #expect(hidden.suppressed.contains("cmux/github-prs"))
        #expect(!hidden.needsInstall("cmux/github-prs"))
        #expect(SidebarBridge.appInfo("cmux/github-prs", client: client).isHidden)
        #expect(sections.title(for: contribution) == nil)

        try await client.set("cmux/github-prs", .hide(false), origin: .cli)
        #expect(AppPresence(client.apps).presented.contains("cmux/github-prs"))
        #expect(SidebarBridge.appInfo("cmux/github-prs", client: client).isHidden == false)
        #expect(sections.title(for: contribution) != nil)
    }

    @Test func disabledIsSuppressedAndNotInstalledNeedsInstall() async throws {
        let (client, _) = await client()
        try await client.set("cmux/agent-status", .enable(false), origin: .user)
        let presence = AppPresence(client.apps)
        #expect(presence.suppressed.contains("cmux/agent-status"))
        #expect(presence.needsInstall("cmux/running-agents"))
    }
}
