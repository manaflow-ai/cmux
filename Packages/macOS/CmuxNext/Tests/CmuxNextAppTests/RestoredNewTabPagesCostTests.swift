import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextInput
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// Hot-path audit 3, H4 (2026-10-28): every window's sidebar rows pass reads which tabs show the New Tab page
/// (`SidebarBridge.newTabPages`, `RestoredNewTabPages.ids`). It walked every tab of every workspace, so the pass
/// observed every pane's tab list: a terminal opened in any workspace re-ran the rows pass of every window, each at
/// O(workspaces + tabs). CLAUDE.md "Go past Chrome where cmux is scripted": a change's model update is O(changed
/// items), never O(session), and observation is targeted (PATTERNS.md). Only a blank chat record can be a restored
/// page, so the read lists the store's blank chat records (`StoreTabRoles`) and observes their set alone.
@MainActor @Suite(.serialized) struct RestoredNewTabPagesCostTests {
    static let host = "install:this-mac"
    static let pageSurface: SurfaceID = 90_000_000

    /// Set from an observation's change callback.
    nonisolated final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        nonisolated var fired: Bool { lock.withLock { value } }
        nonisolated func fire() { lock.withLock { value = true } }
    }

    /// `workspaces` workspaces (handle w, screen w, pane w) of `terminals` terminal tabs each; workspace 1 also
    /// holds a blank chat record, a New Tab page restored after a relaunch.
    static func tree(workspaces: Int, terminals: Int) -> DaemonTree {
        DaemonTree(workspaces: (1...workspaces).map { w in
            var tabs = (0..<terminals).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 1_000 + $0)), title: "zsh") }
            if w == 1 {
                var page = TabSnapshot(surface: pageSurface, kind: .conversation, title: "about:blank", url: "about:blank")
                page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
                tabs.append(page)
            }
            let pane = PaneID(rawValue: UInt64(w))
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(w)), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(w)), key: nil, name: "w\(w)", screens: [screen])
        })
    }

    /// The app's agent tabs after a relaunch: they know this Mac and the store, and have made no view.
    static func agentTabs(_ store: DaemonStore) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), work: BackgroundWork(label: "test.new-tab-pages-cost"),
                                 webUI: .agentTabsTestHost(), input: InputEventTap(), environment: [:], showcase: true)
        tabs.localHost = host
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        return tabs
    }

    static func terminalAdded(workspace w: UInt64, surface: UInt64) -> DaemonEvent {
        .tabAdded(TabDelta(workspace: WorkspaceHandle(rawValue: w), screen: ScreenID(rawValue: w), pane: PaneID(rawValue: w),
                           surface: SurfaceID(rawValue: surface), index: nil, entity: TabSnapshot(surface: SurfaceID(rawValue: surface), title: "zsh")))
    }

    @Test func aTerminalOpenedInAnotherWorkspaceReRunsNoRowsPass() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree(workspaces: 100, terminals: 4))
        let tabs = Self.agentTabs(store)
        let page = try #require(store.tab(surface: Self.pageSurface))
        let fired = Fired()
        let pages = withObservationTracking { SidebarBridge.newTabPages(tabs, in: store) } onChange: { fired.fire() }
        #expect(pages.contains(page.id), "the restored blank chat is listed as a New Tab page")
        // A script opens a terminal in workspace 50, and another in workspace 1 beside the page.
        store.apply(Self.terminalAdded(workspace: 50, surface: 50_999))
        store.apply(Self.terminalAdded(workspace: 1, surface: 1_999))
        #expect(!fired.fired, "a terminal opened in a workspace re-ran the read of the New Tab pages (every window's rows pass)")
    }

    @Test func aNewBlankChatStillReRunsTheReadAndIsListed() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree(workspaces: 10, terminals: 2))
        let tabs = Self.agentTabs(store)
        let fired = Fired()
        _ = withObservationTracking { SidebarBridge.newTabPages(tabs, in: store) } onChange: { fired.fire() }
        var blank = TabSnapshot(surface: 7_777, kind: .conversation, title: "about:blank", url: "about:blank")
        blank.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host))
        store.apply(.tabAdded(TabDelta(workspace: 7, screen: 7, pane: 7, surface: 7_777, index: nil, entity: blank)))
        #expect(fired.fired, "a blank chat record that opens is a New Tab page the rows pass must hear")
        let added = try #require(store.tab(surface: 7_777))
        #expect(SidebarBridge.newTabPages(tabs, in: store).contains(added.id))
        // Its chat starts: it is a chat from here on, not the page.
        var started = blank
        started.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-started", harness: "claude"))
        store.apply(.tabChanged(TabDelta(workspace: 7, screen: 7, pane: 7, surface: 7_777, index: nil, entity: started)))
        #expect(!SidebarBridge.newTabPages(tabs, in: store).contains(added.id))
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    /// The read's cost against the session's size: BENCH lines at 10, 100 and 1000 workspaces of 4 terminals.
    @Test func benchTheReadAtTenAHundredAndAThousandWorkspaces() throws {
        var medians: [Int: Double] = [:]
        for workspaces in [10, 100, 1_000] {
            let store = DaemonStore()
            store.apply(snapshot: Self.tree(workspaces: workspaces, terminals: 4))
            let tabs = Self.agentTabs(store)
            var samples: [Double] = []
            for _ in 0..<101 {
                let start = ContinuousClock.now
                let pages = SidebarBridge.newTabPages(tabs, in: store)
                samples.append(Self.microseconds(ContinuousClock.now - start))
                #expect(pages.count == 1)
            }
            medians[workspaces] = samples.sorted()[samples.count / 2]
            print("BENCH H4 restored-new-tab-pages workspaces=\(workspaces) tabs=\(workspaces * 4 + 1) median_us=\(String(format: "%.2f", medians[workspaces] ?? 0))")
        }
        print("BENCH H4 restored-new-tab-pages ratio_1000_over_10=\(String(format: "%.1f", (medians[1_000] ?? 0) / max(medians[10] ?? 1, 0.001)))")
    }
}
