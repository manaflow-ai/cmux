import CmuxNextCloud
import Foundation
import Testing

/// Cloud first use (``CloudSetup``, cmux-tui/docs/model-connections.md "Cloud first use"): a connection
/// serving the picker's family starts the chat with no prompt; none shows Set up Cloud; a connection
/// that appears afterwards starts it by itself.
@MainActor
@Suite
struct CloudSetupTests {
    /// What the fake reads answer, changed by the test as a person's Settings would.
    @MainActor
    final class Connections {
        var snapshot: CloudSetup.Snapshot
        var reads = 0
        var ran: [CloudSetup.Action] = []
        init(_ snapshot: CloudSetup.Snapshot) { self.snapshot = snapshot }
    }

    private func setup(_ connections: Connections) -> CloudSetup {
        CloudSetup(read: {
            connections.reads += 1
            return connections.snapshot
        }, run: { connections.ran.append($0) })
    }

    @Test func aPersonalConnectionServingTheFamilyStarts() async {
        let connections = Connections(.init(personal: [.init(id: "claude-login", families: ["claude"])], organization: []))
        #expect(await setup(connections).decide(harness: "claude", model: "claude-opus-5-5") == .start)
    }

    @Test func noConnectionShowsSetUpNamingTheModel() async {
        let connections = Connections(.init(personal: [.init(id: "codex-login", families: ["codex"])], organization: []))
        #expect(await setup(connections).decide(harness: "claude", model: "claude-opus-5-5") == .setup(family: "claude", model: "claude-opus-5-5"))
    }

    @Test func aConnectionThatCannotServeDoesNotCount() async {
        let off = CloudSetup.Connection(id: "claude-login", families: ["claude"], enabled: false)
        let signedOut = CloudSetup.Connection(id: "claude-2", families: ["claude"], signedIn: false)
        let connections = Connections(.init(personal: [off, signedOut], organization: nil))
        #expect(await setup(connections).decide(harness: "claude", model: nil) == .setup(family: "claude", model: nil))
    }

    @Test func theOrganizationServesWhenThePersonHasNothing() async {
        let keys = CloudSetup.Snapshot.organization(keys: [("codex", true), ("claude", false)])
        let connections = Connections(.init(personal: [], organization: keys))
        let rule = setup(connections)
        #expect(await rule.decide(harness: "codex", model: nil) == .start)
        #expect(await rule.choose(harness: "codex", model: nil, account: nil) == .organization(family: "codex"))
        #expect(await rule.decide(harness: "claude", model: nil) == .setup(family: "claude", model: nil))
    }

    /// cmux#45773: once a start found the team's shared key unrouted (no machine gets the Cloud service's edge), the key
    /// is no longer chosen, so Set up Cloud waits for a connection of the person's own instead of starting on it again.
    @Test func anUnroutedOrganizationKeyIsNotChosenAgain() async {
        let connections = Connections(.init(personal: [], organization: ["claude"]))
        let rule = setup(connections)
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .organization(family: "claude"))
        rule.organizationUnrouted("claude")
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .setup(family: "claude", model: nil))
        let wait = Task { await rule.waitUntilServed(family: "claude") }
        while connections.reads < 3 { await Task.yield() } // the wait read the team's key alone and parked
        await Task.yield()
        connections.snapshot = .init(personal: [.init(id: "claude-token:1", families: ["claude"])], organization: ["claude"])
        rule.connectionsChanged()
        #expect(await wait.value)
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .connection(id: "claude-token:1", family: "claude"))
    }

    /// cmux#45773: a start whose machine gave its agent no model shows Set up Cloud only when it ran on the team's key and
    /// the next choice is that card; with this Mac's connections unread, or a connection of its own, it answers nil.
    @Test func anUnroutedStartShowsSetUpCloudOnlyForTheTeamsKey() async {
        let rule = setup(Connections(.init(personal: [], organization: ["claude"])))
        let card = await rule.unrouted(harness: "claude", model: "opus", account: nil)
        #expect(card?.family == "claude" && card?.model == "opus")
        #expect(rule.unroutedOrganization == ["claude"])
        #expect(await setup(Connections(.init(personal: nil, organization: ["claude"]))).unrouted(harness: "claude", model: nil, account: nil) == nil)
        #expect(await setup(Connections(.init(personal: [], organization: nil))).unrouted(harness: "claude", model: nil, account: nil) == nil)
        #expect(await rule.unrouted(harness: "gemini", model: nil, account: nil) == nil)
    }

    /// Revision 2's choice: the picker's account when it serves Cloud, else the first enabled
    /// Cloud-serving connection of the family in order, before the organization's key. A Mac CLI login
    /// (`serves_cloud: false`) is never chosen.
    @Test func theChoiceIsThePickersAccountElseTheFirstServingOne() async {
        let login = CloudSetup.Connection(id: "claude-login", families: ["claude"], servesCloud: false)
        let off = CloudSetup.Connection(id: "claude-token:1", families: ["claude"], enabled: false)
        let first = CloudSetup.Connection(id: "claude-token:2", families: ["claude"])
        let key = CloudSetup.Connection(id: "api-key:anthropic", families: ["claude"])
        let plan = CloudSetup.Connection(id: "chatgpt-plan:1", families: ["codex"])
        let rule = setup(Connections(.init(personal: [login, off, first, key, plan], organization: ["claude"])))
        #expect(await rule.choose(harness: "claude", model: "claude-opus-5-5", account: "api-key:anthropic") == .connection(id: "api-key:anthropic", family: "claude"))
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .connection(id: "claude-token:2", family: "claude"))
        // An account that does not serve Cloud (or serves another family) falls to the order.
        #expect(await rule.choose(harness: "claude", model: nil, account: "claude-login") == .connection(id: "claude-token:2", family: "claude"))
        #expect(await rule.choose(harness: "claude", model: nil, account: "chatgpt-plan:1") == .connection(id: "claude-token:2", family: "claude"))
        #expect(await rule.choose(harness: "codex-work", model: nil, account: nil) == .connection(id: "chatgpt-plan:1", family: "codex"))
        #expect(await rule.choose(harness: "opencode", model: nil, account: nil) == .fallback)
        #expect(await setup(Connections(.init(personal: [login], organization: []))).choose(harness: "claude", model: "m", account: "claude-login")
            == .setup(family: "claude", model: "m"))
        #expect(CloudSetup.isConnectionID("chatgpt-plan:1") && !CloudSetup.isConnectionID("a b") && !CloudSetup.isConnectionID(""))
    }

    /// hq#19758: a refusal carries the team gateway read it counted (the team and the CLI's error code), and a read is this
    /// refusal's own: an earlier read's code never rides on a later refusal.
    @Test func aRefusalCarriesItsOwnGatewayRead() async {
        let rule = setup(Connections(.init(personal: [], organization: [])))
        rule.gateway = { [unowned rule] in rule.gatewayRead = CloudSetup.GatewayRead(team: "team_x", errorCode: "timed_out"); return nil }
        #expect(await rule.refusal(harness: "claude", model: nil)?.gateway == CloudSetup.GatewayRead(team: "team_x", errorCode: "timed_out"))
        rule.gateway = { nil }
        rule.gatewayRead = CloudSetup.GatewayRead(team: "team_old", errorCode: "auth.no_token")
        #expect(await rule.refusal(harness: "claude", model: nil)?.gateway == nil)
    }

    /// hq#15762: a team in inference gateway mode with its gateway online serves a person with no connection of their own
    /// (production 2026-11-20 19:54Z: "No Cloud connection serves claude" with the gateway up). It is read only when
    /// nothing else serves, and a connection or the team's key still wins.
    @Test func anOnlineTeamGatewayServesWhenNothingElseDoes() async {
        let connections = Connections(.init(personal: [], organization: []))
        var gatewayReads = 0
        var served: Set<String>? = ["claude", "codex"]
        let rule = setup(connections)
        rule.gateway = { gatewayReads += 1; return served }
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .gateway(family: "claude"))
        #expect(await rule.decide(harness: "codex", model: nil) == .start)
        #expect(CloudSetup.Choice.gateway(family: "claude").connectionID == nil)
        #expect(await rule.waitUntilServed(family: "claude"))
        // A start on it that reached no model route: the card, and Set up Cloud no longer passes on the gateway alone.
        let unrouted = setup(Connections(.init(personal: [], organization: [])))
        unrouted.gateway = { ["claude"] }
        let card = await unrouted.unrouted(harness: "claude", model: "m", account: nil)
        #expect(card?.family == "claude" && card?.model == "m")
        #expect(unrouted.unroutedGateway == ["claude"])
        #expect(await unrouted.decide(harness: "claude", model: nil) == .setup(family: "claude", model: nil))
        // Off, offline (empty) or unread (nil): the card again.
        for value in [Set<String>(), nil] {
            served = value
            #expect(await rule.decide(harness: "claude", model: "m") == .setup(family: "claude", model: "m"))
        }
        // Something else serves: the gateway is not read.
        served = ["claude"]
        gatewayReads = 0
        connections.snapshot = .init(personal: [.init(id: "claude-token:1", families: ["claude"])], organization: ["codex"])
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .connection(id: "claude-token:1", family: "claude"))
        #expect(await rule.choose(harness: "codex", model: nil, account: nil) == .organization(family: "codex"))
        #expect(gatewayReads == 0)
        // An agent Cloud does not serve, or connections unread, never read it either.
        connections.snapshot = .init(personal: nil, organization: nil)
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .fallback)
        #expect(await rule.choose(harness: "opencode", model: nil, account: nil) == .fallback)
        #expect(gatewayReads == 0)
    }

    /// An acpmux that predates `_acpmux/connections` (no daemon either) keeps every start as it was.
    @Test func unreadConnectionsStartAsBefore() async {
        let connections = Connections(.init(personal: nil, organization: []))
        #expect(await setup(connections).decide(harness: "claude", model: nil) == .start)
        #expect(await CloudSetup().decide(harness: "claude", model: nil) == .start)
        #expect(await setup(connections).choose(harness: "claude", model: nil, account: nil) == .fallback)
        // An agent the gateway does not serve is never held back.
        let none = Connections(.init(personal: [], organization: []))
        #expect(await setup(none).decide(harness: "opencode", model: nil) == .start)
    }

    @Test func familiesOfThePickersAgent() {
        #expect(CloudSetup.family(of: "claude") == "claude")
        #expect(CloudSetup.family(of: "codex-work") == "codex")
        #expect(CloudSetup.family(of: nil) == "claude")
        #expect(CloudSetup.family(of: "gemini") == nil)
    }

    @Test func connectionRowsFromTheDaemon() {
        let row: [String: Any] = ["id": "chatgpt-plan:1", "kind": "chatgpt-plan", "families": ["codex"], "signed_in": true, "enabled": false, "serves_cloud": true]
        #expect(CloudSetup.Connection(json: row) == .init(id: "chatgpt-plan:1", families: ["codex"], enabled: false))
        #expect(CloudSetup.Connection(json: ["families": ["codex"]]) == nil)
    }

    /// The card's button runs its way in, and the wait ends once a connection serving the family
    /// appears (a ``CloudSetup/connectionsChanged()`` after Settings added it), with no retyping.
    @Test func aConnectionThatAppearsStartsTheChat() async {
        let connections = Connections(.init(personal: [], organization: []))
        let rule = setup(connections)
        let ready = Task { await rule.setUp(.connectChatGPT, family: "codex") }
        // The wait has read (after the action) and parked: nothing serves yet.
        while connections.reads < 1 { await Task.yield() }
        await Task.yield()
        #expect(connections.ran == [.connectChatGPT])
        connections.snapshot.personal = [.init(id: "chatgpt-plan:1", families: ["codex"])]
        rule.connectionsChanged()
        #expect(await ready.value)
    }

    /// The page withdrew (it left Cloud, or Not now): the wait ends with no connection.
    @Test func aCancelledWaitEnds() async {
        let connections = Connections(.init(personal: [], organization: []))
        let rule = setup(connections)
        let wait = Task { await rule.waitUntilServed(family: "claude") }
        while connections.reads < 1 { await Task.yield() }
        wait.cancel()
        #expect(await wait.value == false)
    }
}
