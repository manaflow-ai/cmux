import CmuxNextAccounts
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Connectors' relay: every request acts for the account and team the click was made in, and a
/// device restricted to a managed team never falls back to the person's own connectors.
@MainActor
@Suite struct SettingsConnectorsTests {
    private let click = PageCallContext(page: "cmux.settings", userGesture: true)
    private let listing = Data(#"{"connectors":[]}"#.utf8)
    private let approval = Data(#"{"provider":"github","url":"https://github.com/apps/cmux/installations/new"}"#.utf8)

    @Test func managedTeamMissingSendsNothingForThePerson() async throws {
        var team: String? = nil
        var sent: [String] = []
        var opened: [URL] = []
        let relay = SettingsConnectors(scope: {
            GitHubConnections.signedInScope(project: "project", user: "user", team: team, managedTeam: "managed")
        }, send: { _, path, _, _ in
            sent.append(path)
            return (200, path.hasSuffix("install") ? approval : listing)
        }, open: { opened.append($0) }, preview: false)
        // The managed team is not available (nil) or another team is selected: nothing goes out.
        for other in [nil, "another"] as [String?] {
            team = other
            let list = try await relay.call("cmux.settings.connectors.list", params: .object([:]), context: click)
            #expect(list["signedIn"] == .bool(false))
            await #expect(throws: PageError.self) {
                _ = try await relay.call("cmux.settings.connectors.connect",
                                         params: ["provider": "github", "sharing": "team"], context: click)
            }
            await #expect(throws: PageError.self) {
                _ = try await relay.call("cmux.settings.connectors.disconnect",
                                         params: ["provider": "github", "connection": "conn_aaaaaaaaaaaaaaaaaaaa"], context: click)
            }
        }
        #expect(sent.isEmpty)
        #expect(opened.isEmpty)
        team = "managed"
        _ = try await relay.call("cmux.settings.connectors.list", params: .object([:]), context: click)
        #expect(sent == ["v1/connectors/"])
    }

    @Test func aTeamSwitchDuringTheRequestOpensNoApprovalPage() async throws {
        var team: String? = "team-a"
        var scopes: [GitHubConnections.Scope] = []
        var opened: [URL] = []
        let relay = SettingsConnectors(scope: {
            GitHubConnections.signedInScope(project: "project", user: "user", team: team, managedTeam: nil)
        }, send: { _, _, query, bound in
            scopes.append(bound)
            #expect(query == ["sharing": "team"])
            team = "team-b" // The person switches teams while the request is out.
            return (200, approval)
        }, open: { opened.append($0) }, preview: false)
        await #expect(throws: PageError.self) {
            _ = try await relay.call("cmux.settings.connectors.connect", params: ["provider": "github", "sharing": "team"], context: click)
        }
        #expect(scopes == [GitHubConnections.Scope(user: GitHubConnections.backendUser(project: "project", stackUser: "user"), team: "team-a")])
        #expect(opened.isEmpty)
        // In the new team, a fresh click acts for it.
        let answer = try await relay.call("cmux.settings.connectors.connect", params: ["provider": "github", "sharing": "team"],
                                          context: click)
        #expect(answer["opened"] == .bool(true))
        #expect(scopes.last?.team == "team-b")
        #expect(opened.count == 1)
    }

    @Test func connectAndDisconnectNeedTheSettingsPageAndAClick() async {
        var sent = 0
        let relay = SettingsConnectors(scope: { GitHubConnections.Scope(user: "user", team: nil) },
                                       send: { _, _, _, _ in sent += 1; return (200, approval) },
                                       open: { _ in }, preview: false)
        for context in [PageCallContext(page: "cmux.settings"), PageCallContext(page: "cmux.history", userGesture: true)] {
            await #expect(throws: PageError.self) {
                _ = try await relay.call("cmux.settings.connectors.connect", params: ["provider": "github"], context: context)
            }
        }
        #expect(sent == 0)
    }
}
