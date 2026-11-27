import AppKit
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// NIGHTLY 85b099928a8a (Lawrence 2026-11-10, "lots of laggy"): naming a restored New Tab page
/// (`TabTitleResolver.untitled` -> `AgentHistoryPage.title`) looked its key up with no machine, and
/// `AgentTabStore.tabKey` then listed every agent tab of every workspace (`listTabsScoped`). The
/// link chips' places name every tab, so one title change walked the session once per such tab.
/// A tab's name reads the tab's own daemon (`daemonListing`), never the tab list.
@MainActor @Suite(.serialized)
struct TabTitleNoTabListWalkTests {
    @Test func namingEveryTabListsNoTabs() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = "install:this-mac"
        services.agentTabs.localHost = host
        let count: UInt64 = 30
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: (1...count).map { id in
            // A blank chat record restored after a relaunch (a New Tab page), a started chat and a terminal.
            var page = TabSnapshot(surface: SurfaceID(rawValue: id * 10), kind: .conversation, title: "about:blank", url: "about:blank")
            page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
            var chat = TabSnapshot(surface: SurfaceID(rawValue: id * 10 + 1), kind: .conversation, title: "Fix the build", url: "about:blank")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-\(id)", harness: "claude"))
            let terminal = TabSnapshot(surface: SurfaceID(rawValue: id * 10 + 2), kind: .pty, title: "zsh")
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [page, chat, terminal])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
        }))
        let tabs = services.agentTabs
        let listed = ListCounter()
        let list = tabs.listTabsScoped
        tabs.listTabsScoped = { [listed] in
            listed.calls += 1
            return list()
        }
        let title = SidebarBridge.tabTitle(services)
        var pages = 0
        for workspace in services.machines.local.store.workspaces {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where title(workspace, tab) == Strings.untitledBrowser {
                pages += 1
            }
        }
        #expect(pages == Int(count), "each restored blank chat is named New Tab")
        #expect(listed.calls == 0, "naming \(count * 3) tabs listed every agent tab \(listed.calls) times")
    }
}

@MainActor private final class ListCounter {
    var calls = 0
}
