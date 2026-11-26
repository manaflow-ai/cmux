import CmuxNextActions
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

// Leo, 2026-11-17 (ask-5a353e9fa1): "why should it get held only be aperson's click? i dont like that".
// An agent's or the CLI's `macScreen.open` (`cmux tab new-mac-screen --device NAME [--scope view|full]`) on
// one of the person's own devices starts viewing at once, opened in the background or not, and the tab says
// who started it. A device not in the person's list, or Only Your Click Starts Viewing a Screen on, keeps
// the Connect card; a person's open is unchanged.

@MainActor @Suite(.serialized)
struct MacScreenAgentStartTests {
    private let device = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddee02"
    private let stranger = "5d1e0f2a-6b7c-4d8e-9f01-23456789abce"

    private var devices: [HubDevice] { [HubDevice(id: device, name: "gcp-agent-lane-1")] }

    private func pages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "screen-agent-start-\(UUID().uuidString)/store.json")
        return MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
    }

    private func cliOpen(_ name: String, scope: String? = nil) -> ActionInvocation {
        var arguments: [String: ActionValue] = ["device": .string(name)]
        if let scope { arguments["scope"] = .string(scope) }
        return ActionInvocation(arguments: arguments, origin: .cli)
    }

    private func row(_ pages: MacScreenPages, _ key: String) throws -> [String: CmuxNextSettings.JSONValue] {
        let tab = try #require(pages.tab(key))
        return try #require(MacScreenPages.stateRow(tab).objectValue)
    }

    /// The CLI alone, on the person's own device: the tab is made and asks the hub at once with the scope it named
    /// (no hub in a test, so the ask ends "not signed in"), without the tab being shown, and names its agent.
    @Test(arguments: [(nil, SessionScope.view), ("view", .view), ("full", .full)] as [(String?, SessionScope)])
    func anAgentsOpenOfAnOwnDeviceAsksAtOnce(scope: String?, asked: SessionScope) throws {
        let pages = pages()
        let record = try MacScreenActions.record(cliOpen("gcp-agent-lane-1", scope: scope), pages: pages, devices: devices,
                                                 startedBy: { _ in "Fix the login bug" })
        #expect(record.deviceID == device)
        pages.prepare("a", record: record, byPerson: false)
        let pane = try #require(pages.tab("a")?.pane, "the view is made at once: a background tab asks too")
        let hub = try #require(pane.model.hub)
        #expect(hub.phase == .refused(.notSignedIn, requested: asked))
        #expect(hub.lastScope == asked)
        #expect(pane.model.startedBy == MacScreenStarter(name: "Fix the login bug"))
        #expect(pane.model.startedBy?.label.contains("Fix the login bug") == true)
        #expect(pages.pendingScopes.isEmpty && pages.pendingStarters.isEmpty)

        let state = try row(pages, "a")
        #expect(state["started_by"]?.stringValue == "Fix the login bug")
        #expect(state["hub_phase"]?.stringValue == "refused" && state["error"]?.stringValue != nil)
        pages.tabClosed("a")
    }

    /// An agent that names no chat, terminal or app is "an agent".
    @Test func anUnnamedAgentIsAnAgent() throws {
        let pages = pages()
        let record = try MacScreenActions.record(cliOpen(device), pages: pages, devices: devices, startedBy: { _ in "  " })
        pages.prepare("a", record: record, byPerson: false)
        let pane = try #require(pages.tab("a")?.pane)
        #expect(pane.model.startedBy == MacScreenStarter(name: nil))
        #expect(try row(pages, "a")["started_by"]?.stringValue == "agent")
        pages.tabClosed("a")
    }

    /// A device id not in the person's own list keeps the Connect card: nothing pending, nothing asked.
    @Test func anAgentsOpenOfADeviceNotTheirsWaitsAtTheConnectCard() throws {
        let pages = pages()
        let record = try MacScreenActions.record(cliOpen(stranger, scope: "full"), pages: pages, devices: devices,
                                                 startedBy: { _ in "Fix the login bug" })
        #expect(record.deviceID == stranger)
        #expect(pages.pendingScopes.isEmpty && pages.pendingStarters.isEmpty)
        try expectConnectCard(pages, record: record)
    }

    /// Only Your Click Starts Viewing a Screen on: automation waits at the Connect card, own device or not.
    @Test func theSettingOnWaitsAtTheConnectCard() throws {
        let pages = pages()
        pages.onlyPersonStartsViewing = true
        let record = try MacScreenActions.record(cliOpen("gcp-agent-lane-1", scope: "full"), pages: pages, devices: devices,
                                                 startedBy: { _ in "Fix the login bug" })
        #expect(pages.pendingScopes.isEmpty && pages.pendingStarters.isEmpty)
        try expectConnectCard(pages, record: record)
    }

    /// A person's open is as before: View Only, asked when the tab shows, whatever `scope` says, and no starter.
    @Test func aPersonsOpenIsUnchanged() throws {
        let pages = pages()
        var invocation = cliOpen("gcp-agent-lane-1", scope: "full")
        invocation.origin = .user
        let result = ActionRunScope.$current.withValueInTask(ActionRunScope(origin: .user, allowsViewChange: true)) {
            Result { try MacScreenActions.record(invocation, pages: pages, devices: devices, startedBy: { _ in "Fix the login bug" }) }
        }
        let record = try result.get()
        #expect(pages.pendingScopes[device] == .view && pages.pendingStarters.isEmpty)
        pages.prepare("a", record: record, byPerson: true)
        #expect(pages.tab("a") == nil, "a person's tab is made when it shows")
        _ = pages.makeView(for: "a")
        let pane = try #require(pages.tab("a")?.pane)
        #expect(pane.model.hub?.phase == .idle)
        #expect(pane.model.hub?.resumeScope == .view, "it asks for View Only when shown")
        #expect(pane.model.startedBy == nil)
        #expect(try row(pages, "a")["started_by"] == CmuxNextSettings.JSONValue.null)
        pages.tabClosed("a")
    }

    /// A tab restored on an agent-started device's route waits at the Connect card again.
    @Test func aRestoredTabOfAnAgentsStartWaits() throws {
        let pages = pages()
        let record = try MacScreenActions.record(cliOpen(device), pages: pages, devices: devices)
        pages.prepare("a", record: record, byPerson: false)
        pages.tabClosed("a")
        pages.restore(MacScreenPages.route(of: record), for: "b")
        try expectConnectCard(pages, record: record, key: "b")
    }

    private func expectConnectCard(_ pages: MacScreenPages, record: MacScreenRecord, key: String = "a") throws {
        pages.prepare(key, record: record, byPerson: false)
        #expect(pages.tab(key) == nil, "nothing is made before the tab shows")
        _ = pages.makeView(for: key)
        let pane = try #require(pages.tab(key)?.pane)
        #expect(pane.model.hub?.phase == .idle)
        #expect(pane.model.hub?.resumeScope == nil)
        #expect(pane.model.startedBy == nil)
        let state = try row(pages, key)
        #expect(state["hub_phase"]?.stringValue == "idle")
        #expect(state["started_by"] == CmuxNextSettings.JSONValue.null)
        pages.tabClosed(key)
    }
}
