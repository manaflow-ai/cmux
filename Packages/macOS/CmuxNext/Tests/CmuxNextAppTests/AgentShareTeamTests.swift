import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// Team shares bind the native consent to the selected account, team and chat before minting a
/// scoped token. These tests keep the refusal boundary independent of the hosted daemon.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentShareTeamTests {
    @MainActor final class Host: AgentShareHost {
        let services: AppServices
        var accountScope: String? = "account-1"
        var teams = [AgentShareTeam(id: "team-1", name: "Platform")]
        var asks: [AgentShareConsentAsk] = []
        var tokenCalls: [(URL?, String, String)] = []
        var allow = true
        var chatVisible = true
        var beforeAnswer: (() -> Void)?

        init(_ services: AppServices) { self.services = services }
        func shareTab(surface: SurfaceID) -> TabModel? { services.shareTab(surface: surface) }
        func shareTab(id: String) -> TabModel? { services.shareTab(id: id) }
        func shareTabID(showing session: String) -> String? { chatVisible ? services.shareTabID(showing: session) : nil }
        var shareFocusedTabID: String? { nil }
        func shareConnection(holding tab: TabModel) -> DaemonConnection? { nil }
        func shareIsOnThisMac(_ tab: TabModel) -> Bool { true }
        var shareLocalConnection: DaemonConnection? { nil }
        func shareOwnerToken(api: URL?) async -> String? { "legacy-token" }
        var shareAccountScope: String? { accountScope }
        var shareTeams: [AgentShareTeam] { teams }
        func shareTeamOwnerToken(api: URL?, team: String, accountScope: String) async -> String? {
            tokenCalls.append((api, team, accountScope))
            return "team-token"
        }
        func shareCopy(_ text: String) {}
        func shareNotice(_ message: String) {}
        func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool {
            asks.append(ask)
            beforeAnswer?()
            return allow
        }
        func shareShowInvites(_ model: AgentShareInviteSheetModel) {}
        func shareChanges(_ changed: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void { {} }
        func shareOpenSettings(route: String) {}
        func shareTitle(of tab: TabModel) -> String { tab.displayTitle }
    }

    private func chat() -> (AgentShareTests.Fixture, AgentShareChat) {
        let fixture = AgentShareTests.fixture()
        return (fixture, AgentShareChat(surface: 1, session: AgentShareTests.session, connection: nil, title: "Fix the build"))
    }

    @Test func teamConsentNamesTheTeamAndRoleAndDeclineMintsNothing() async throws {
        let (fixture, chat) = chat()
        let host = Host(fixture.services)
        host.allow = false

        await #expect(throws: AgentShareDeclined.self) {
            try await AgentShareActions.confirmTeam("team-1", role: "talk", chat: chat, host: host)
        }
        let ask = try #require(host.asks.first)
        #expect(ask.team == AgentShareTeam(id: "team-1", name: "Platform"))
        #expect(ask.teamRole == "talk")
        #expect(ask.title.contains("Platform"))
        #expect(ask.lines.contains { $0.contains("talk") })
        #expect(host.tokenCalls.isEmpty)
    }

    @Test func staleAccountAfterConsentFailsClosedBeforeTokenMint() async {
        let (fixture, chat) = chat()
        let host = Host(fixture.services)
        host.beforeAnswer = { host.accountScope = "different-account" }

        await #expect(throws: AgentShareTeamUnavailable.self) {
            try await AgentShareActions.confirmTeam("team-1", role: "view", chat: chat, host: host)
        }
        #expect(host.tokenCalls.isEmpty)
    }

    @Test func staleChatAfterConsentFailsClosedBeforeTokenMint() async {
        let (fixture, chat) = chat()
        let host = Host(fixture.services)
        host.beforeAnswer = { host.chatVisible = false }

        await #expect(throws: AgentShareTeamUnavailable.self) {
            try await AgentShareActions.confirmTeam("team-1", role: "view", chat: chat, host: host)
        }
        #expect(host.tokenCalls.isEmpty)
    }

    @Test func unknownTeamIsRefusedBeforeConsent() async {
        let (fixture, chat) = chat()
        let host = Host(fixture.services)

        await #expect(throws: AgentShareTeamUnavailable.self) {
            try await AgentShareActions.confirmTeam("missing", role: "view", chat: chat, host: host)
        }
        #expect(host.asks.isEmpty)
        #expect(host.tokenCalls.isEmpty)
    }

    @Test func omittedTeamRoleAsksForViewBeforeMinting() async {
        let (fixture, chat) = chat()
        let host = Host(fixture.services)
        host.allow = false

        await #expect(throws: AgentShareDeclined.self) {
            try await AgentShareActions.create(chat, ttl: nil, uses: nil, team: "team-1", host: host)
        }
        #expect(host.asks.first?.teamRole == "view")
        #expect(host.tokenCalls.isEmpty)
    }
}
