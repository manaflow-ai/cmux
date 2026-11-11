import AppKit
import CmuxNextDaemon
import CmuxNextTabs
import Testing
@testable import CmuxNextApp

/// NIGHTLY 85b099928a8a, "Cmd-T is slow" (Lawrence 2026-11-10). #36767 keyed an agent tab's state by
/// (machine, id). A caller that has the tab's id alone (`AgentTabStore.tabKey(_:machine: nil)`: Cmd-T's
/// `isAgentTab(selected)`, the key router, the strip, the toolbar) then listed every agent tab of every
/// workspace of every machine (`listTabsScoped`) each time the id was not a known chat, which is every
/// terminal and every browser tab. The cost of one key press grew with the session. A tab id is looked up
/// in each machine's own tab index (`DaemonStore.tab(id:)`), never by a walk of the tab list.
@MainActor @Suite(.serialized)
struct AgentTabBareKeyNoSessionWalkTests {
    private static let host = "install:this-mac"

    /// `count` workspaces, each with one pane of a started chat and a terminal, on this Mac's store.
    private static func services(workspaces count: UInt64) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.agentTabs.localHost = host
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: (1...count).map { id in
            var chat = TabSnapshot(surface: SurfaceID(rawValue: id * 10 + 1), kind: .conversation, title: "Fix the build", url: "about:blank")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-\(id)", harness: "claude"))
            let terminal = TabSnapshot(surface: SurfaceID(rawValue: id * 10 + 2), kind: .pty, title: "zsh")
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [chat, terminal])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
        }))
        return services
    }

    /// Counts the walks of the session's tab list that `body` makes.
    private static func tabListWalks(_ tabs: AgentTabStore, during body: () -> Void) -> Int {
        let listed = WalkCounter()
        let list = tabs.listTabsScoped
        tabs.listTabsScoped = { [listed] in
            listed.calls += 1
            return list()
        }
        defer { tabs.listTabsScoped = list }
        body()
        return listed.calls
    }

    /// What Cmd-T asks about the selected tab in its key turn (`TabLifecycle.newTabOfPaneKind`), for a terminal.
    @Test func askingWhetherATerminalIsAChatWalksNoTabList() throws {
        let services = Self.services(workspaces: 40)
        let tabs = services.agentTabs
        let terminals = services.machines.local.store.workspaces
            .flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }.filter { $0.agentSession == nil }.map(\.id)
        try #require(terminals.count == 40, "fixture: one terminal per workspace")
        var chats = 0
        let walks = Self.tabListWalks(tabs) {
            for id in terminals where tabs.isAgentTab(id) || tabs.isNewTabPage(id) || tabs.existingView(id) != nil { chats += 1 }
        }
        #expect(chats == 0, "a terminal is no chat and no New Tab page")
        #expect(walks == 0, "asking about \(terminals.count) terminals walked the whole session's tab list \(walks) times")
    }

    /// The same question about a chat that has no page yet (a restored chat in a pane not shown since launch).
    @Test func askingAboutAChatWithNoPageYetWalksNoTabList() throws {
        let services = Self.services(workspaces: 40)
        let tabs = services.agentTabs
        let machine = services.machines.local.machineID
        let chats = services.machines.local.store.workspaces
            .flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }.filter { $0.agentSession != nil }.map(\.id)
        try #require(chats.count == 40, "fixture: one chat per workspace")
        var found = 0
        let walks = Self.tabListWalks(tabs) {
            for id in chats where tabs.isAgentTab(id) && tabs.tabKey(id) == AgentTabKey(machine: machine, key: id) { found += 1 }
        }
        #expect(found == chats.count, "a chat's id alone names the chat on the one machine that lists it")
        #expect(walks == 0, "asking about \(chats.count) chats walked the whole session's tab list \(walks) times")
    }

    /// The answers the walk gave stay: state held under the id, an id two machines hold, and a store tab
    /// still under its provisional id after the creation answered with the real one.
    @Test func aBareIDStillNamesTheSameTab() throws {
        let services = Self.services(workspaces: 3)
        let tabs = services.agentTabs
        let machine = services.machines.local.machineID
        let chat = try #require(services.machines.local.store.workspaces.first?.screens.first?.panes.first?.tabs.first { $0.agentSession != nil }?.id)
        let here = AgentTabKey(machine: machine, key: chat)
        // The store lists it under `chat`; the creation's answer named it "tab_real" (`rekey`).
        tabs.aliases[here] = "tab_real"
        #expect(tabs.tabKey("tab_real") == here, "the real id names the tab the store still lists under its first id")
        #expect(tabs.tabKey(chat) == here)
        _ = tabs.aliases.removeValue(forKey: here)
        // State under the id, on one machine and then on two.
        tabs.sessions[here] = "s-here"
        #expect(tabs.tabKey(chat) == here)
        tabs.sessions[AgentTabKey(machine: "forked-machine", key: chat)] = "s-there"
        #expect(tabs.tabKey(chat) == AgentTabKey(machine: "", key: chat), "an id two machines hold names neither")
        #expect(tabs.tabKey(chat, machine: machine) == here)
        tabs.sessions[AgentTabKey(machine: "forked-machine", key: chat)] = nil
        #expect(tabs.tabKey(chat) == here)
        // No tab at all.
        #expect(tabs.tabKey("tab_nowhere") == AgentTabKey(machine: "", key: "tab_nowhere"))
    }

    /// `AgentTabMap` answers "which machines hold this id" from its id index through every kind of change.
    @Test func theMapFindsAnIDsMachinesThroughEveryChange() {
        var map = AgentTabMap<Int>()
        let a = AgentTabKey(machine: "a", key: "tab_1"), b = AgentTabKey(machine: "b", key: "tab_1"), other = AgentTabKey(machine: "a", key: "tab_2")
        map[a] = 1
        map[other] = 2
        #expect(map.onlyKey(ofTab: "tab_1") == a)
        map[a] = 3 // a second write of one key is still one machine
        #expect(map.keys(ofTab: "tab_1") == [a])
        map[b] = 4
        #expect(Set(map.keys(ofTab: "tab_1")) == [a, b])
        #expect(map.onlyKey(ofTab: "tab_1") == nil, "an id two machines hold names neither")
        let kept = map.filter { $0.value != 3 } as AgentTabMap<Int>
        #expect(kept.onlyKey(ofTab: "tab_1") == b)
        map[a] = nil
        #expect(map.onlyKey(ofTab: "tab_1") == b)
        let removed = map.removeValue(forKey: b)
        #expect(removed == 4)
        #expect(map.keys(ofTab: "tab_1").isEmpty)
        let removedAgain = map.removeValue(forKey: b)
        #expect(removedAgain == nil)
        #expect(map.onlyKey(ofTab: "tab_2") == other)
        #expect(map.count == 1)
    }
}

@MainActor private final class WalkCounter {
    var calls = 0
}
