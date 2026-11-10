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

    /// The `scope` RELAY's list gave the page, as the page sends it back.
    private func shown(_ relay: SettingsConnectors) async throws -> JSONValue {
        let list = try await relay.call("cmux.settings.connectors.list", params: .object([:]), context: click)
        return list["scope"] ?? .null
    }

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
        var switchDuringSend = true
        var opened: [URL] = []
        let relay = SettingsConnectors(scope: {
            GitHubConnections.signedInScope(project: "project", user: "user", team: team, managedTeam: nil)
        }, send: { _, path, query, bound in
            guard path.hasSuffix("install") else { return (200, listing) }
            scopes.append(bound)
            #expect(query == ["sharing": "team"])
            if switchDuringSend { team = "team-b" } // The person switches teams while the request is out.
            return (200, approval)
        }, open: { opened.append($0) }, preview: false)
        let inA = try await shown(relay)
        await #expect(throws: PageError.self) {
            _ = try await relay.call("cmux.settings.connectors.connect",
                                     params: ["provider": "github", "sharing": "team", "scope": inA], context: click)
        }
        #expect(scopes == [GitHubConnections.Scope(user: GitHubConnections.backendUser(project: "project", stackUser: "user"), team: "team-a")])
        #expect(opened.isEmpty)
        // The page still shows team A (its sharing prompt stayed open through the switch): refused before any request.
        switchDuringSend = false
        await #expect(throws: PageError.self) {
            _ = try await relay.call("cmux.settings.connectors.connect",
                                     params: ["provider": "github", "sharing": "team", "scope": inA], context: click)
        }
        #expect(scopes.count == 1)
        // Once the page reads the list for team B, a click there acts for B.
        let inB = try await shown(relay)
        #expect(inB != inA)
        let answer = try await relay.call("cmux.settings.connectors.connect",
                                          params: ["provider": "github", "sharing": "team", "scope": inB], context: click)
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
