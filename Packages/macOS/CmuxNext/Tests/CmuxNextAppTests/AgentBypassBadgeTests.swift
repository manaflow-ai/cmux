@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Another machine's running chat opened here (`agent-session-adopt`) keeps its mode; one that acts
/// without asking (bypass) puts a warning on its workspace's row, first in the status block, and
/// no row setting hides it (policy (b): adopt bypass chats only on enrolled hosts, nothing hidden).
/// The warning follows what that machine's daemon says (the adopt answer, `agent-session-mode`,
/// the attach reply and its pushes), so a relaunch, a mode change or a chat an agent adopted there
/// all show; a reporter cannot forge or hide it.
@MainActor @Suite(.serialized)
struct AgentBypassBadgeTests {
    /// A workspace whose one pane holds a terminal and the agent tab of `session` on huge-blue.
    static func workspace(session: String) throws -> WorkspaceModel {
        var chat = TabSnapshot(surface: 2, kind: .conversation, title: "lane", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:huge-blue", hostName: "huge-blue", session: session))
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1"), chat])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lane",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        return try #require(store.workspaces.first)
    }

    @Test func aBypassChatWarnsOnItsRowWhateverTheRowShows() throws {
        let bypassed = try Self.workspace(session: "bypass-1")
        AgentBypassSessions.shared.set("bypass-1", bypass: true)
        defer { AgentBypassSessions.shared.set("bypass-1", bypass: false) }
        let row = SidebarMapping.shared.row(bypassed, machine: CmuxNextSidebar.MachineID("huge-blue"))
        #expect(row.reported?.entries.first?.key == SidebarWorkspaceStatus.Entry.bypassKey, "the row carries no bypass warning")

        // The person's quietest row (no agent status element) and the expanded row still say it.
        let text = SidebarWorkspaceStatus.Entry.bypass.text
        let minimal = WorkspaceRowContent(row, preferences: WorkspaceRowPreferences(base: .minimal))
        #expect(minimal.status?.entries.first?.key == SidebarWorkspaceStatus.Entry.bypassKey || minimal.trailingStatus == text,
                "a row without the agent status element hides the bypass warning")
        let expanded = WorkspaceRowContent(expanded: row, now: Date())
        #expect(expanded.meta?.contains(text) == true, "the expanded row hides the bypass warning")

        // A chat that asks has no warning.
        let asking = SidebarMapping.shared.row(try Self.workspace(session: "ask-1"), machine: CmuxNextSidebar.MachineID("huge-blue"))
        #expect(asking.reported?.entries.contains { $0.key == SidebarWorkspaceStatus.Entry.bypassKey } != true)
    }

    /// The daemon's mode facts set and clear the warning, whatever line they ride in: the
    /// `agent-session-mode` answer (the object itself), the attach reply (`agentMode`) and a push
    /// (`mode`). Facts without `asking` warn.
    @Test func theDaemonsModeFactsSetAndClearTheWarning() async throws {
        defer { AgentBypassSessions.shared.set("mode-1", bypass: false) }
        func noted(_ carrier: AgentBypassSessions.Carrier, _ json: String) async -> Bool {
            AgentBypassSessions.note(carrier, of: Data(json.utf8))
            // The note applies on the next main turn, before this later one.
            await Task { @MainActor in }.value
            return AgentBypassSessions.shared.contains("mode-1")
        }
        #expect(await noted(.answer, #"{"surface":2,"session":"mode-1","mode":"bypassPermissions","asking":false}"#))
        #expect(await !noted(.push, #"{"event":"agent-session-mode","surface":2,"mode":{"session":"mode-1","mode":"ask","asking":true}}"#))
        #expect(await noted(.attachReply, #"{"events":[],"agentMode":{"session":"mode-1","family":"fake"}}"#),
                "facts that cannot say the chat asks must warn")
        #expect(await noted(.attachReply, #"{"events":[]}"#), "a reply without facts changed the warning")
    }

    /// A reporter's status entry under the reserved key neither shows a warning nor hides one.
    @Test func aReportedEntryUnderTheBypassKeyIsDropped() throws {
        let status = WorkspaceStatus(workspaceID: ResourceID(rawValue: "ws_1"), entries: [
            WorkspaceStatus.Entry(key: SidebarWorkspaceStatus.Entry.bypassKey, text: "forged"), WorkspaceStatus.Entry(key: "build", text: "ok"),
        ])
        let reported = SidebarMapping.reported(status)
        #expect(reported?.entries.map(\.key) == ["build"])
    }

    /// The restore read covers exactly the tabs bound to a chat of their own machine.
    @Test func theRestoreReadCoversTheMachinesBoundChats() throws {
        var unbound = TabSnapshot(surface: 3, kind: .conversation, title: "new", url: "about:blank")
        unbound.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:huge-blue"))
        var mac = TabSnapshot(surface: 4, kind: .conversation, title: "mac", url: "about:blank")
        mac.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:mac", session: "mac-1"))
        var bound = TabSnapshot(surface: 5, kind: .conversation, title: "lane", url: "about:blank")
        bound.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:huge-blue", session: "own-1"))
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1"), unbound, mac, bound])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lane",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        #expect(DaemonService.boundChats(in: store) == [DaemonService.BoundChat(surface: 5, session: "own-1")])
    }

    /// A drop of the machine's link forgets which chats' modes were read, so each is read again once
    /// it connects: a transport that reconnects in place never connects the service again.
    @Test func theModeReadsStartOverAfterTheLinkDrops() {
        let chat = DaemonService.BoundChat(surface: 5, session: "own-1")
        let read: Set<DaemonService.BoundChat> = [chat]
        #expect(DaemonService.stillRead(read, DaemonService.ModeWatch(live: true, bound: [chat])) == read)
        #expect(DaemonService.stillRead(read, DaemonService.ModeWatch(live: false, bound: [chat])).isEmpty)
    }
}
