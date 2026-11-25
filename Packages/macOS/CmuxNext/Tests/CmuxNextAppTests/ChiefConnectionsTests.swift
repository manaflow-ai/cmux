import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The Chief card's Gmail and Google Calendar rows (cmux issue 34263) over the owner API's
/// `integration.*` ops, with a recorded call in place of the network.
@MainActor
@Suite struct ChiefConnectionsTests {
    private let scope = ChiefConnections.Scope(user: "user_me", team: nil)
    private let providers: JSONValue = [["provider": "gmail", "configured": true], ["provider": "google_calendar", "configured": true],
                                        ["provider": "github", "configured": true]]

    @Test func signedOutShowsSignInAndNeverCallsTheAPI() async {
        var calls = 0
        let model = ChiefConnections(scope: { nil }, call: { _, _, _, _ in calls += 1; return [:] }, open: { _ in })
        await model.refresh()
        await model.connect(.gmail)
        #expect(calls == 0)
        #expect(model.state(.gmail) == .signedOut)
        #expect(HomeChiefConnection(model, .gmail).state == .signedOut)
    }

    @Test func connectOpensOnlyGooglesConsentPageThenShowsTheConnectedAccount() async {
        var operations: [String] = []
        var opened: [URL] = []
        var approved = false
        let model = ChiefConnections(scope: { self.scope }, call: { _, op, params, key in
            operations.append(op)
            switch op {
            case "integration.connect":
                #expect(params == ["provider": "gmail", "sharing": "private"])
                #expect(key != nil)
                approved = true
                return ["connection": ["id": "conn_aaaaaaaaaaaaaaaaaaaa"],
                        "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&state=s"]
            default:
                let rows: JSONValue = approved
                    ? [["id": "conn_aaaaaaaaaaaaaaaaaaaa", "provider": "gmail", "status": "active", "created_by": "user_me",
                        "account": ["key": "gmail:1", "name": "me@example.com"]]]
                    : []
                return ["connections": rows, "providers": self.providers]
            }
        }, open: { opened.append($0) })
        await model.refresh()
        #expect(model.state(.gmail) == .notConnected)
        #expect(HomeChiefConnection(model, .gmail).action == .connect)
        await model.connect(.gmail)
        #expect(operations == ["integration.list", "integration.connect", "integration.list"])
        #expect(opened.map(\.host) == ["accounts.google.com"])
        #expect(model.state(.gmail) == .connected(account: "me@example.com"))
        #expect(model.state(.googleCalendar) == .notConnected)
        let row = HomeChiefConnection(model, .gmail)
        #expect(row.status == "me@example.com")
        #expect(row.action == .disconnect)
    }

    @Test func aConnectAnsweringAnotherSiteOpensNothing() async {
        var opened: [URL] = []
        let model = ChiefConnections(scope: { self.scope }, call: { _, op, _, _ in
            if op == "integration.connect" {
                return ["connection": ["id": "conn_aaaaaaaaaaaaaaaaaaaa"], "authorize_url": "https://accounts.google.com.evil.example/o/oauth2/v2/auth"]
            }
            return ["connections": [], "providers": self.providers]
        }, open: { opened.append($0) })
        await model.refresh()
        await model.connect(.googleCalendar)
        #expect(opened.isEmpty)
        #expect(model.failed)
        for raw in ["http://accounts.google.com/o/oauth2/v2/auth", "https://user@accounts.google.com/o/oauth2/v2/auth",
                    "https://accounts.google.com:444/o/oauth2/v2/auth", "https://accounts.google.com/signin"] {
            #expect(ChiefConnections.authorizeURL(raw) == nil)
        }
    }

    @Test func onlyTheMakerMayDisconnectAndAnUnconfiguredProviderIsUnavailable() async {
        var revoked: [JSONValue] = []
        let model = ChiefConnections(scope: { self.scope }, call: { _, op, params, _ in
            if op == "integration.revoke" { revoked.append(params) }
            return ["connections": [["id": "conn_bbbbbbbbbbbbbbbbbbbb", "provider": "gmail", "status": "active", "created_by": "user_teammate",
                                     "sharing": "team", "account": ["key": "gmail:2", "name": "team@example.com"]]],
                    "providers": [["provider": "gmail", "configured": true], ["provider": "google_calendar", "configured": false]]]
        }, open: { _ in })
        await model.refresh()
        #expect(model.state(.gmail) == .connected(account: "team@example.com"))
        #expect(!model.canDisconnect(.gmail))
        #expect(HomeChiefConnection(model, .gmail).action == nil)
        await model.disconnect(.gmail)
        #expect(revoked.isEmpty)
        #expect(model.state(.googleCalendar) == .unavailable)
    }

    @Test func aRevokedGrantAsksToConnectAgain() async {
        let model = ChiefConnections(scope: { self.scope }, call: { _, _, _, _ in
            ["connections": [["id": "conn_cccccccccccccccccccc", "provider": "google_calendar", "status": "needs_reauth", "created_by": "user_me",
                              "account": ["key": "google_calendar:1", "name": "me@example.com"]]],
             "providers": self.providers]
        }, open: { _ in })
        await model.refresh()
        #expect(model.state(.googleCalendar) == .needsReauth(account: "me@example.com"))
        #expect(HomeChiefConnection(model, .googleCalendar).action == .reconnect)
    }

    @Test func aListForTheOldAccountIsDropped() async {
        var current: ChiefConnections.Scope? = scope
        let model = ChiefConnections(scope: { current }, call: { _, _, _, _ in
            current = .init(user: "user_other", team: nil)
            return ["connections": [["id": "conn_dddddddddddddddddddd", "provider": "gmail", "status": "active", "created_by": "user_me"]],
                    "providers": self.providers]
        }, open: { _ in })
        await model.refresh()
        #expect(model.state(.gmail) == .unavailable)
    }

    @Test func aSuccessfulRefreshClearsAnEarlierFailure() async {
        var failing = true
        let model = ChiefConnections(scope: { self.scope }, call: { _, _, _, _ in
            if failing { throw URLError(.timedOut) }
            return ["connections": [], "providers": self.providers]
        }, open: { _ in })
        await model.refresh()
        #expect(model.failed)
        failing = false
        await model.refresh()
        #expect(!model.failed)
        #expect(model.state(.gmail) == .notConnected)
    }

    @Test func disconnectRevokesOnlyTheConnectionTheRowShows() async {
        var revoked: [JSONValue] = []
        // A teammate's active team connection and the person's own broken one.
        let model = ChiefConnections(scope: { self.scope }, call: { _, op, params, _ in
            if op == "integration.revoke" { revoked.append(params) }
            return ["connections": [
                ["id": "conn_eeeeeeeeeeeeeeeeeeee", "provider": "gmail", "status": "active", "created_by": "user_teammate", "sharing": "team",
                 "account": ["key": "gmail:2", "name": "team@example.com"]],
                ["id": "conn_ffffffffffffffffffff", "provider": "gmail", "status": "needs_reauth", "created_by": "user_me",
                 "account": ["key": "gmail:1", "name": "me@example.com"]],
            ], "providers": self.providers]
        }, open: { _ in })
        await model.refresh()
        #expect(model.state(.gmail) == .connected(account: "team@example.com"))
        #expect(!model.canDisconnect(.gmail))
        await model.disconnect(.gmail)
        #expect(revoked.isEmpty)
    }

    @Test func aSecondConnectWhileGoogleIsOpenReplaysTheSameKey() async {
        var keys: [String?] = []
        let model = ChiefConnections(scope: { self.scope }, call: { _, op, _, key in
            if op == "integration.connect" {
                keys.append(key)
                return ["connection": ["id": "conn_aaaaaaaaaaaaaaaaaaaa"], "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth?state=s"]
            }
            let rows: JSONValue = keys.isEmpty ? [] : [["id": "conn_aaaaaaaaaaaaaaaaaaaa", "provider": "gmail", "status": "pending", "created_by": "user_me"]]
            return ["connections": rows, "providers": self.providers]
        }, open: { _ in })
        await model.refresh()
        await model.connect(.gmail)
        #expect(model.state(.gmail) == .pending)
        await model.connect(.gmail)
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1])
    }

    @Test func theVaultListsEachNameOnceWithoutItsScope() {
        let index: [String: Int64] = ["*/OPENAI_API_KEY": 1, "manaflow-ai/cmux/OPENAI_API_KEY": 2, "*/STRIPE_KEY": 3]
        #expect(CloudMachineSecrets.names(in: index) == ["OPENAI_API_KEY", "STRIPE_KEY"])
        #expect(CloudMachineSecrets.names(in: [:]).isEmpty)
    }
}
