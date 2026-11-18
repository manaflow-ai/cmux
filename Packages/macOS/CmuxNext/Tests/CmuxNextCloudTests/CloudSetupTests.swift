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

    // cmux#45774: the Mac's Codex CLI login and a machine whose daemon predates its credential.
    private static let login = CloudSetup.Connection(id: "codex-login", families: ["codex"], kind: "codex-login")
    private static let added = CloudSetup.Connection(id: "codex-2", families: ["codex"], kind: "subscription")
    private static let key = CloudSetup.Connection(id: "openai-key", families: ["codex"], kind: "api-key")

    /// A machine that does not take the Codex CLI login gets the next connection serving Codex on Cloud (an OpenAI key),
    /// never an added Codex CLI account; with none the start is refused before anything is sent (the team's key is no
    /// way on: machines get no route from it). A daemon that takes the login, and any other connection, keep the choice.
    @Test func aCodexCLILoginFallsBackOnAMachineThatDoesNotTakeIt() async throws {
        let connections = Connections(.init(personal: [Self.login, Self.added, Self.key], organization: nil))
        let rule = setup(connections)
        let (base, account, other) = (await rule.isCodexLogin("codex-login"), await rule.isCodexLogin("codex-2"), await rule.isCodexLogin("openai-key"))
        #expect(base && account && !other)
        #expect(try await rule.connection("codex-login", harness: "codex", model: nil, account: nil, takesCodexLogin: true) == "codex-login")
        #expect(try await rule.connection("codex-login", harness: "codex", model: nil, account: nil, takesCodexLogin: false) == "openai-key")
        #expect(try await rule.connection("openai-key", harness: "codex", model: nil, account: nil, takesCodexLogin: false) == "openai-key")
        #expect(try await rule.connection(nil, harness: "codex", model: nil, account: nil, takesCodexLogin: false) == nil)
        connections.snapshot = .init(personal: [Self.login, Self.added], organization: ["codex"])
        await #expect(throws: CloudSetup.CodexLoginUnsupported.self) {
            try await rule.connection("codex-login", harness: "codex", model: nil, account: nil, takesCodexLogin: false)
        }
        // The kind comes from `_acpmux/connections`; a row without one (an older acpmux) is no Codex CLI login.
        #expect(CloudSetup.Connection(json: ["id": "codex-login", "families": ["codex"], "kind": "codex-login"])?.isCodexLogin == true)
        #expect(CloudSetup.Connection(json: ["id": "codex-login", "families": ["codex"]])?.isCodexLogin == false)
    }

    /// A chat's start refused unsent for its Codex CLI login (`app.codex_login_unsupported`, an older machine daemon) goes
    /// once more on the next connection serving Codex on Cloud, and that is the credential the chat runs (and refreshes) on;
    /// with none the refusal stands on the login's credential.
    @Test func aStartRefusedForItsCodexCLILoginGoesOnceMoreOnAnotherConnection() async throws {
        let connections = Connections(.init(personal: [Self.login, Self.key], organization: nil))
        let replies = ["codex-login": #"{"family":"codex","kind":"codex-login","env":{"CMUX_CODEX_ACCESS_TOKEN":"eyJhbGciOi.codex.c2ln"},"expires_at":1900000000}"#,
                       "openai-key": #"{"family":"codex","kind":"api-key","env":{"OPENAI_API_KEY":"sk-proj-x"}}"#]
        let credentials = CloudAgentCredentials { id in Data(replies[id, default: "{}"].utf8) }
        credentials.setup = setup(connections)
        let chosen = try await credentials.launchCredential(chat: "tab-1", machine: "vm-1", harness: "codex")
        #expect(chosen?.connectionID == "codex-login" && chosen?.isCodexLogin == true)
        let refusal = AgentSessionAttachError(code: AgentSessionAttachClient.codexLoginUnsupported, message: "older daemon")
        var sent: [[String]] = []
        let (result, used) = await CloudAgentCredentials.sending(chosen, with: credentials, chat: "tab-1", machine: "vm-1", harness: "codex", model: nil) { env in
            sent.append(env?.keys.sorted() ?? [])
            if env?["CMUX_CODEX_ACCESS_TOKEN"] != nil { throw refusal }
            return "session-1"
        }
        #expect(sent == [["CMUX_CODEX_ACCESS_TOKEN"], ["OPENAI_API_KEY"]])
        #expect((try? result.get()) == "session-1")
        #expect(used?.connectionID == "openai-key")

        connections.snapshot = .init(personal: [Self.login], organization: nil)
        let (alone, kept) = await CloudAgentCredentials.sending(chosen, with: credentials, chat: "tab-1", machine: "vm-1", harness: "codex", model: nil) { _ -> String in
            throw refusal
        }
        #expect(kept?.connectionID == "codex-login")
        guard case .failure(let error as AgentSessionAttachError) = alone else { Issue.record("the refusal did not stand"); return }
        #expect(error.code == AgentSessionAttachClient.codexLoginUnsupported)
        await #expect(throws: CloudAgentCredentials.Failure.codexLoginUnsupported) {
            try await credentials.launchCredential(chat: "tab-1", machine: "vm-1", harness: "codex", takesCodexLogin: false)
        }
    }
}
