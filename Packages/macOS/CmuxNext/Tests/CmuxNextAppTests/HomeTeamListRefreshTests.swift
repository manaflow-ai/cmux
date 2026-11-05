import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxNextTestSupport
@testable import MessagesLabSidebar
import Testing

/// Lawrence 2026-10-24: "by default, i should see every person in my team as contacts in the
/// imessage list". The list draws every teammate without a DM as a row, but the team is read after
/// the page opens (and again when a team is joined): the list must redraw when the read lands.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows) struct HomeTeamListRefreshTests {
    @Test func teammatesAppearInTheListWhenTheTeamIsRead() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = TopHomePageView(services: services, windowKey: { "team-list-refresh" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer { window.close() }
        let ada = HomeContact(id: ParticipantID("user_ada"), name: "Ada Lovelace", source: .team)
        let grace = HomeContact(id: ParticipantID("user_grace"), name: "Grace Hopper", source: .team)
        let rows = { page.list.list.entries.map(\.id) }
        services.home.directory.teamMembers = [ada, grace]
        let deadline = ContinuousClock.now + .seconds(10)
        while !rows().contains(HomeSidebarView.teammateRowID(ada)), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(rows().contains(HomeSidebarView.teammateRowID(ada)))
        #expect(rows().contains(HomeSidebarView.teammateRowID(grace)))
    }
}
