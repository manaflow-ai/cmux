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
        var opened: [String] = []
        init(_ snapshot: CloudSetup.Snapshot) { self.snapshot = snapshot }
    }

    private func setup(_ connections: Connections) -> CloudSetup {
        CloudSetup(read: {
            connections.reads += 1
            return connections.snapshot
        }, run: { action, family, _ in
            connections.ran.append(action)
            connections.opened.append(family)
        })
    }

    @Test func allowsNativeClaudeSignInBeforeTheFirstCloudChat() async {
        let setup = CloudSetup(read: { .init(personal: [], organization: []) })
        setup.canSignInToClaudeOnMachine = { $0 == nil || $0 == "owner" }
        #expect(await setup.served().families["claude"] == nil)
        #expect(await setup.served(machine: "owner").families["claude"] == nil)
        #expect(await setup.served(machine: "team").families["claude"] == false)
    }

    @Test func aSavedClaudeTokenFromTheCLIServesACloudStart() async throws {
        let token = try #require(CloudSetup.Connection(json: [
            "id": "claude-token", "kind": "claude-token", "families": ["claude"], "serves_cloud": true,
        ]))
        let rule = setup(Connections(.init(personal: [token], organization: [])))
        #expect(await rule.choose(harness: "claude", model: nil, account: nil) == .connection(id: "claude-token", family: "claude"))
        #expect(await rule.served().families["claude"] == true)
    }

    @Test func aHeldClaudeSendWaitsForApprovalOnItsOwnMachine() async {
        let connections = Connections(.init(personal: [.init(id: "claude-token", families: ["claude"])], organization: []))
        let rule = setup(connections)
        rule.run = { [weak rule] _, _, machine in
            #expect(machine == "vm_b")
            rule?.claudeSignInCompleted(machine: "vm_a")
        }
        #expect(await rule.setUp(.setUpClaude, family: "claude", machine: "vm_b"))
        #expect(connections.reads == 1)

        rule.run = { [weak rule] _, _, machine in
            if let machine { rule?.claudeSignInCompleted(machine: machine) }
        }
        #expect(await rule.setUp(.setUpClaude, family: "claude", machine: "vm_b"))
        #expect(connections.reads == 1)
        rule.run = nil
    }

    @Test func exactEndpointReadinessAndStartUseTheSameConnection() async {
        let connections = Connections(.init(personal: [
            .init(id: "deepseek", families: ["deepseek"], endpointProfile: true, endpointCredentials: true, launchHarness: "opencode"),
            .init(id: "claude-local", families: ["claude-local"], servesCloud: false, endpointProfile: true),
        ], organization: ["claude"]))
        let rule = setup(connections)
        #expect(await rule.choose(harness: "deepseek", model: "byo/model", account: nil) == .connection(id: "deepseek", family: "deepseek"))
        #expect(await rule.choose(harness: "claude-local", model: nil, account: nil) == .setup(family: "claude-local", model: nil))
        #expect(await rule.launchConnection("deepseek")?.endpointCredentials == true)
        let unknown = await rule.served()
        #expect(unknown.servedHarnesses.isEmpty)
        #expect(unknown.pendingHarnesses == ["deepseek"])
        rule.machineHarnesses = { $0 == "current" ? ["opencode"] : [] }
        let served = await rule.served(machine: "current")
        #expect(served.servedHarnesses == ["deepseek"])
        #expect(served.unavailableEndpointHarnesses == ["claude-local"])
        let missing = await rule.served(machine: "current-without-opencode")
        #expect(missing.pendingHarnesses.isEmpty)
        #expect(missing.unavailableEndpointHarnesses == ["claude-local", "deepseek"])
    }

    @Test func aSubscriptionRunnerStaysPendingUntilTheMachineAcceptsItsCredential() async {
        let rule = setup(Connections(.init(personal: [
            .init(id: "copilot", families: ["github-copilot"], endpointCredentials: true, launchHarness: "opencode", subscriptionCredentials: true),
            .init(id: "openrouter", families: ["openrouter"], endpointCredentials: true, launchHarness: "opencode"),
        ], organization: [])))
        rule.machineHarnesses = { _ in ["opencode"] }
        let pending = await rule.served(machine: "cloud")
        #expect(pending.pendingHarnesses == ["github-copilot"])
        #expect(pending.servedHarnesses == ["openrouter"])
        rule.machineSubscriptionHarnesses = { _ in ["opencode"] }
        let ready = await rule.served(machine: "cloud")
        #expect(ready.pendingHarnesses.isEmpty)
        #expect(ready.servedHarnesses == ["github-copilot", "openrouter"])
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
    /// the next choice is that card. Without an organization route, this recovery path is unused.
    @Test func anUnroutedStartShowsSetUpCloudOnlyForTheTeamsKey() async {
        let rule = setup(Connections(.init(personal: [], organization: ["claude"])))
        let card = await rule.unrouted(harness: "claude", model: "opus", account: nil)
        #expect(card?.family == "claude" && card?.model == "opus")
        #expect(rule.unroutedOrganization == ["claude"])
        #expect(await setup(Connections(.init(personal: nil, organization: ["claude"]))).unrouted(harness: "claude", model: nil, account: nil)?.family == "claude")
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
        #expect(await rule.choose(harness: "opencode", model: nil, account: nil) == .setup(family: "opencode", model: nil))
        #expect(await setup(Connections(.init(personal: [login], organization: []))).choose(harness: "claude", model: "m", account: "claude-login")
            == .setup(family: "claude", model: "m"))
        #expect(CloudSetup.isConnectionID("chatgpt-plan:1") && !CloudSetup.isConnectionID("a b") && !CloudSetup.isConnectionID(""))
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

    /// CMUX-662: the picker's Connect rows read the same answer a start would get, per family, before any send.
    @Test func servedAnswersEachFamilyAsAStartWouldDecideIt() async {
        let claude = CloudSetup.Connection(id: "claude-login", families: ["claude"])
        let connections = Connections(.init(personal: [claude], organization: []))
        #expect(await setup(connections).served().families == ["claude": true, "codex": false])
        // The team's shared key serves Codex, until a start finds it unrouted.
        connections.snapshot = .init(personal: [], organization: ["codex"])
        let teamKey = setup(connections)
        #expect(await teamKey.served().families == ["claude": false, "codex": true])
        teamKey.organizationUnrouted("codex")
        #expect(await teamKey.served().families == ["claude": false, "codex": false])
        // Unread connections and no team key decide nothing: no family is named.
        connections.snapshot = .init(personal: nil, organization: nil)
        #expect(await setup(connections).served().families.isEmpty)
        #expect(await CloudSetup().served().families.isEmpty)
        // The team's keys unread (still loading): "not served" is unknown, so it names only what serves.
        connections.snapshot = .init(personal: [claude], organization: nil)
        #expect(await setup(connections).served().families == ["claude": true])
    }

    @Test func readinessExplainsKnownMissingConnections() async {
        let local = CloudSetup.Connection(id: "claude-login", families: ["claude"], servesCloud: false)
        let off = CloudSetup.Connection(id: "claude-token", families: ["claude"], signedIn: false, enabled: false)
        let signedOut = CloudSetup.Connection(id: "chatgpt-plan", families: ["claude", "codex"], signedIn: false)
        let connections = Connections(.init(personal: [local], organization: []))
        let rule = setup(connections)
        let signedOutOfCloud = await rule.served()
        #expect(signedOutOfCloud.families == ["claude": false, "codex": false])
        #expect(signedOutOfCloud.reasons == ["claude": CloudSetup.ConnectionReason.none, "codex": .none])

        connections.snapshot.personal = [local, off]
        let disabled = await rule.served()
        #expect(disabled.reasons == ["claude": .off, "codex": .none])

        connections.snapshot.personal = [local, off, signedOut]
        let expired = await rule.served()
        #expect(expired.reasons == ["claude": .signedOut, "codex": .signedOut])

        connections.snapshot.organization = nil
        let loading = await rule.served()
        #expect(loading.families.isEmpty && loading.reasons.isEmpty)
        connections.snapshot.organization = ["claude"]
        let team = await rule.served()
        #expect(team.families == ["claude": true, "codex": false])
        #expect(team.reasons == ["codex": .signedOut])
    }

    @Test func readinessExplainsAnEligibleConnectionWithCloudTurnedOff() async throws {
        let key = try #require(CloudSetup.Connection(json: [
            "id": "anthropic-key", "families": ["claude"], "can_serve_cloud": true,
            "serves_cloud": false, "signed_in": true, "enabled": true,
        ]))
        let connections = Connections(.init(personal: [key], organization: []))
        let rule = setup(connections)
        let readiness = await rule.served()
        #expect(readiness.families["claude"] == false)
        #expect(readiness.reasons["claude"] == .cloudOff)
        connections.snapshot.personal = []
        #expect(await rule.served().reasons["claude"] == CloudSetup.ConnectionReason.none)
    }

    @Test func pickerConnectOpensSettingsForTheSelectedFamily() {
        let connections = Connections(.init(personal: [], organization: []))
        let setup = setup(connections)
        var opened: [String] = []
        setup.openConnectionSettings = { family, machine, _ in opened.append(machine.map { "\(family):\($0)" } ?? family) }
        setup.connect(family: "codex")
        setup.connect(family: "gemini")
        setup.connect(family: "claude", machine: "vm_b")
        #expect(opened == ["codex", "gemini", "claude:vm_b"])
        #expect(connections.ran.isEmpty)
    }

    @Test(arguments: CloudSetup.setupFamilies)
    func onlyConfirmedMissingConnectionsAskForSetup(family: String) async {
        let connections = Connections(.init(personal: nil, organization: []))
        let rule = setup(connections)
        let required = CloudSetup.Choice.setup(family: family, model: "fixture/model")
        #expect(await rule.choose(harness: family, model: "fixture/model", account: nil) == .fallback)
        #expect(await CloudSetup().choose(harness: family, model: "fixture/model", account: nil) == .fallback)
        connections.snapshot.personal = []
        #expect(await rule.choose(harness: family, model: "fixture/model", account: nil) == required)
        connections.snapshot.personal = [.init(id: "connected", families: [family])]
        #expect(await rule.choose(harness: family, model: "fixture/model", account: nil) == .connection(id: "connected", family: family))
    }

    @Test func otherHarnessProfilesAlsoRequireAConnection() async {
        let none = Connections(.init(personal: [], organization: []))
        let rule = setup(none)
        let family = "providers/custom"
        #expect(await rule.decide(harness: family, model: nil) == .setup(family: family, model: nil))
        #expect(CloudSetup.isSetupFamily(family) && !CloudSetup.isSetupFamily("providers//custom"))
        none.snapshot.personal = [.init(id: "custom", families: [family])]
        #expect(await rule.choose(harness: family, model: nil, account: nil) == .connection(id: "custom", family: family))
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
        #expect(connections.opened == ["codex"])
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
