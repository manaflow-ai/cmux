import CmuxNextCloud
import CmuxNextDaemon
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

    @Test func onlyLiveOwnerLoginsInTheSelectedEnvironmentAreReady() async {
        let setup = CloudSetup(read: { .init(personal: [], organization: []) })
        var wrong = CloudMachine(id: "wrong")
        wrong.environmentId = "env_a"
        var right = CloudMachine(id: "right", displayName: "chosen")
        right.environmentId = "env_b"
        var signedOut = CloudMachine(id: "signed-out")
        signedOut.environmentId = "env_b"
        var oldGuest = CloudMachine(id: "old-guest")
        oldGuest.environmentId = "env_b"
        var paused = CloudMachine(id: "paused", status: .paused)
        paused.environmentId = "env_b"
        let machines = [wrong, right, signedOut, oldGuest, paused]
        setup.claudeMachines = { machines }
        setup.readClaudeMachineLogin = { ["wrong", "right", "paused"].contains($0) }
        #expect(await setup.readyClaudeMachines(environment: "env_b") == ["right"])
        #expect(await setup.readyClaudeMachines(machine: "wrong", environment: "env_b").isEmpty)
        #expect(await setup.readyClaudeMachines(name: "chosen") == ["right"])
        #expect(await setup.served(machine: "right", environment: "env_b").families["claude"] == true)
        #expect(await setup.served(machine: "wrong", environment: "env_b").environmentMatches == false)
        #expect(await setup.served(machine: "right", environment: "env_b").environmentMatches == true)
        #expect(await setup.served(machine: "old-guest").families["claude"] == false)
        #expect(await setup.refusal(harness: "claude", model: nil, readyClaude: true) == nil)
        #expect(await setup.refusal(harness: "claude", model: nil, readyClaude: false)?.family == "claude")
        setup.openConnectionSettings = { _, _, _, _, _ in Issue.record("an existing login must skip Settings") }
        #expect(await setup.setUp(.setUpClaude, family: "claude", environment: "env_b")
                == .init(machine: "right", usesMachineLogin: true, environment: "env_b", bindsEnvironment: true))
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
        #expect(await rule.setUp(.setUpClaude, family: "claude", machine: "vm_b") == CloudSetup.SetupCompletion(machine: "vm_b", bindsEnvironment: true))
        #expect(connections.reads == 1)

        rule.run = { [weak rule] _, _, machine in
            if let machine { rule?.claudeSignInCompleted(machine: machine) }
        }
        #expect(await rule.setUp(.setUpClaude, family: "claude", machine: "vm_b") == CloudSetup.SetupCompletion(machine: "vm_b", usesMachineLogin: true, bindsEnvironment: true))
        #expect(connections.reads == 1)
        rule.run = nil
    }

    @Test func staleEndpointAndOpenRouterRowsNeverOfferACloudLaunch() async throws {
        let endpoint = try #require(CloudSetup.Connection(json: [
            "id": "deepseek", "kind": "endpoint", "families": ["deepseek"], "serves_cloud": true,
            "launch_harness": "opencode", "endpoint_credentials": true,
        ]))
        let openRouter = try #require(CloudSetup.Connection(json: [
            "id": "openrouter-key", "kind": "api-key", "provider": "openrouter",
            "cloud_families": ["claude", "openrouter"], "serves_cloud": true,
            "launch_harness": "claude", "endpoint_credentials": true,
        ]))
        let rule = setup(Connections(.init(personal: [endpoint, openRouter], organization: [])))
        rule.machineHarnesses = { _ in ["claude", "opencode"] }
        #expect(await rule.choose(harness: "deepseek", model: "byo/model", account: nil) == .localOnly)
        #expect(await rule.choose(harness: "openrouter", model: nil, account: nil) == .localOnly)
        #expect(await rule.choose(harness: "claude", model: nil, account: "openrouter-key") == .setup(family: "claude", model: nil))
        let readiness = await rule.served(machine: "guest")
        #expect(readiness.servedHarnesses.isEmpty)
        #expect(readiness.pendingHarnesses.isEmpty)
        #expect(readiness.unavailableEndpointHarnesses == ["deepseek"])
    }

    @Test(arguments: [false, true])
    func aGuestWithoutTheAdvertisedClaudeTeamRouteRetriesOnlyWhenSignedIn(signedIn: Bool) async throws {
        let rule = setup(Connections(.init(personal: [], organization: ["claude"])))
        let choice = await rule.choose(harness: "claude", model: nil, account: nil)
        let refusal = AgentSessionAttachError(code: "agent_session.route_unavailable", message: "unavailable",
                                               details: .object(["reason": .string("route.unavailable")]))
        var starts: [AgentSessionAttachClient.ClaudeAuth?] = []
        var statusChecks = 0
        do {
            let session = try await CloudSetup.startWithClaudeFallback(choice.claudeAuth, isSignedIn: {
                statusChecks += 1
                return signedIn
            }) { auth in
                starts.append(auth)
                if auth == .team { throw refusal }
                return "session"
            }
            #expect(signedIn && session == "session")
        } catch let error as AgentSessionAttachError {
            #expect(!signedIn && error == refusal)
        }
        #expect(starts == (signedIn ? [.team, .own] : [.team]))
        #expect(statusChecks == 1)
    }

    @Test func aSuccessfulOrUnrelatedTeamStartNeverChecksMachineLogin() async throws {
        let session = try await CloudSetup.startWithClaudeFallback(.team, isSignedIn: {
            Issue.record("A working team route should not check the other account")
            return true
        }) { auth in
            #expect(auth == .team)
            return "session"
        }
        #expect(session == "session")

        let refusal = AgentSessionAttachError(code: "agent_session.host_unverified", message: "unverified")
        await #expect(throws: refusal) {
            try await CloudSetup.startWithClaudeFallback(.team, isSignedIn: {
                Issue.record("An unrelated refusal should not check the other account")
                return true
            }) { _ in throw refusal }
        }
    }

    @Test func staleCloudPlanRowsCannotDisplaceARunnableKeyOrOfferTheirRunners() async {
        let rule = setup(Connections(.init(personal: [
            .init(id: "grok-plan", families: ["grok"], endpointCredentials: true, launchHarness: "grok", subscriptionCredentials: true, kind: "grok-plan"),
            .init(id: "copilot-plan", families: ["github-copilot"], endpointCredentials: true, launchHarness: "opencode", subscriptionCredentials: true, kind: "copilot-plan"),
            .init(id: "kimi-plan", families: ["opencode"], endpointCredentials: true, launchHarness: "opencode", kind: "kimi-plan"),
            .init(id: "xai-key", families: ["grok"], endpointCredentials: true, launchHarness: "grok", kind: "api-key"),
        ], organization: [])))
        rule.machineHarnesses = { _ in ["opencode", "grok"] }
        rule.machineSubscriptionHarnesses = { _ in ["opencode", "grok"] }
        let readiness = await rule.served(machine: "cloud")
        #expect(readiness.pendingHarnesses.isEmpty)
        #expect(readiness.servedHarnesses == ["grok", "xai-key"])
        #expect(await rule.choose(harness: "grok", model: nil, account: "grok-plan") == .connection(id: "xai-key", family: "grok"))
        #expect(await rule.choose(harness: "github-copilot", model: nil, account: "copilot-plan") == .fallback)
        #expect(await rule.choose(harness: "opencode", model: nil, account: "kimi-plan") == .fallback)
        #expect(await rule.launchConnection("kimi-plan") == nil)
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

    @Test(arguments: ["claude", "codex"])
    func anExplicitKeyOptOutRefusesEvenWithOtherCloudAccounts(family: String) async {
        let selected = CloudSetup.Connection(id: "selected", families: [family])
        let other = CloudSetup.Connection(id: "other", families: [family])
        let connections = Connections(.init(personal: [other, selected], organization: [family]))
        let rule = setup(connections)
        rule.gateway = { [family] }
        #expect(await rule.choose(harness: family, model: nil, account: selected.id).connectionID == selected.id)

        let optedOut = CloudSetup.Connection(id: selected.id, families: [family], servesCloud: false, canServeCloud: true)
        connections.snapshot.personal = [other, optedOut]
        #expect(await rule.launchReadiness(harness: family, model: nil, account: selected.id, readyClaude: true).choice == .localOnly)
        #expect(await rule.choose(harness: family, model: nil, account: nil).connectionID == other.id)
        connections.snapshot.personal = [optedOut]
        #expect(await rule.launchReadiness(harness: family, model: nil, account: selected.id, readyClaude: true).choice == .localOnly)
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
        // The mark holds for gatewayUnroutedHold, not the app run: past it the gateway is asked again and the start goes on
        // (start-matrix-production run 45857917362: one unrouted machine refused the 15 claude rows after it).
        let marked = Date()
        unrouted.now = { marked.addingTimeInterval(CloudSetup.gatewayUnroutedHold - 1) }
        #expect(await unrouted.decide(harness: "claude", model: nil) == .setup(family: "claude", model: nil))
        unrouted.now = { marked.addingTimeInterval(CloudSetup.gatewayUnroutedHold + 1) }
        #expect(unrouted.unroutedGateway.isEmpty)
        #expect(await unrouted.decide(harness: "claude", model: nil) == .start)
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
        setup.openConnectionSettings = { family, machine, _, _, _ in opened.append(machine.map { "\(family):\($0)" } ?? family) }
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
    @Test func machineSignInOnAnotherAccountCannotReleaseTheOldSend() async {
        var account = ["team-a"]
        let connections = Connections(.init(personal: [.init(id: "cloud-token", families: ["claude"])], organization: []))
        let rule = setup(connections)
        rule.accountScope = { account }
        rule.run = { [weak rule] _, _, _ in
            account = ["team-b"]
            rule?.claudeSignInCompleted(machine: "vm_b")
        }
        #expect(await rule.setUp(.setUpClaude, family: "claude") == nil)
        #expect(connections.reads == 1, "another account's sign-in did not satisfy the wait")
    }

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
        #expect(await ready.value == CloudSetup.SetupCompletion(bindsEnvironment: true))
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
