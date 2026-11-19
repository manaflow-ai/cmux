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

    /// A team's shared key alone serves no Cloud chat: the Cloud service keeps it sealed and never answers it to a client
    /// (backend team-agent-keys.ts), and gives machines no model route to spend it through (cmux#45583), so the Mac has
    /// nothing to send with the chat's `session/new` (cmux#40159). A team-key-only start shows Set up Cloud before any
    /// machine, as a person with nothing does, instead of a machine whose first turn says "Not logged in".
    @Test func aTeamSharedKeyAloneServesNoCloudChat() async {
        let keys = CloudSetup.Snapshot.organization(keys: [("codex", true), ("claude", true)])
        let rule = setup(Connections(.init(personal: [], organization: keys)))
        for family in ["claude", "codex"] {
            #expect(await rule.decide(harness: family, model: "m") == .setup(family: family, model: "m"))
            #expect(await rule.choose(harness: family, model: "m", account: nil) == .setup(family: family, model: "m"))
        }
        // Its refusal names the team's key.
        #expect(await rule.sharedKeyOnly(harness: "claude"))
        // A connection of the person's own still serves beside the team's key, and then nothing names the key.
        let own = setup(Connections(.init(personal: [.init(id: "claude-token:1", families: ["claude"])], organization: keys)))
        #expect(await own.choose(harness: "claude", model: nil, account: nil) == .connection(id: "claude-token:1", family: "claude"))
        #expect(await !own.sharedKeyOnly(harness: "claude"))
        // Nothing at all, or this Mac's connections unread: no key to name.
        #expect(await !setup(Connections(.init(personal: [], organization: []))).sharedKeyOnly(harness: "claude"))
        #expect(await !setup(Connections(.init(personal: nil, organization: ["claude"]))).sharedKeyOnly(harness: "claude"))
        #expect(await setup(Connections(.init(personal: nil, organization: ["claude"]))).choose(harness: "claude", model: nil, account: nil) == .fallback)
        // Set up Cloud's wait is not satisfied by the team's key: it waits for a connection of the person's own.
        let connections = Connections(.init(personal: [], organization: ["claude"]))
        let waiting = setup(connections)
        let wait = Task { await waiting.waitUntilServed(family: "claude") }
        while connections.reads < 1 { await Task.yield() }
        await Task.yield()
        connections.snapshot = .init(personal: [.init(id: "claude-token:1", families: ["claude"])], organization: ["claude"])
        waiting.connectionsChanged()
        #expect(await wait.value)
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
}
