import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo (ask-bdd706af47): opening a pane or a workspace must not get slower with the number of workspaces. The
/// window's structural sidebar pass read the New Tab page set of the whole session (every tab of the store) and
/// handed it to every row by value, so a New Tab page opened in ONE workspace (Cmd-T, a split, Cmd-N's first page)
/// changed the pass's inputs and mapped every row of the window again.
///
/// A New Tab page made in one workspace maps that workspace's row only. The pass is the window's own
/// (`SidebarBridge.passSections`, which `observe()` runs) through a row feed whose frame the test runs by hand, so
/// every count is exact and nothing waits on time.
@MainActor @Suite(.serialized) struct SidebarNewTabPagePassTests {
    nonisolated static let count = 40
    static let host = "install:this-mac"
    static var keys: [String] { (0..<count).map { String(format: "k%03d", $0) } }
    /// The workspace a New Tab page opens in.
    static let opened = "k000"

    /// Workspace `key`: a terminal, plus a blank chat tab (a New Tab page as the store keeps it) when `page`.
    static func workspace(_ key: String, index: Int, page: Bool = false) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: base + 1), kind: .pty, cwd: "/tmp/\(key)")]
        if page {
            var blank = TabSnapshot(surface: SurfaceID(rawValue: base + 2), kind: .conversation, title: "about:blank", url: "about:blank")
            blank.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
            tabs.append(blank)
        }
        let pane = PaneSnapshot(id: PaneID(rawValue: base), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(PaneID(rawValue: base)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    static func tree(page: Bool = false) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.map { key in
            workspace(key, index: Int(key.dropFirst())!, page: page && key == opened)
        })
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        private(set) var listed: [SidebarWorkspace] = []

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.agentTabs.localHost = SidebarNewTabPagePassTests.host
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: SidebarNewTabPagePassTests.tree())
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"new-tab-pass","workspace_key":"new-tab-pass-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = SidebarNewTabPagePassTests.keys
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            feed.onChange = { [weak self] changed in self?.patch(changed) }
            pass()
            frame()
        }

        /// The window's structural pass: every listed row named, new rows mapped and observed.
        func pass() {
            let (sections, _, _) = SidebarBridge.passSections(services, window: state, feed: feed, rows: feed.rowSource)
            listed = feed.fill(sections).flatMap(\.workspaces)
        }

        /// One display frame: the row feed's flush maps its dirty rows again.
        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }

        private func patch(_ changed: [SidebarWorkspace]) {
            for row in changed { if let at = listed.firstIndex(where: { $0.id == row.id }) { listed[at] = row } }
        }

        /// The rows mapped again by the pass and the frame that follow `body`.
        func mapped(_ body: () -> Void) -> Int {
            _ = SidebarPerfCounters.report(reset: true)
            body()
            pass()
            frame()
            return SidebarPerfCounters.report(reset: true)["row_maps"] ?? 0
        }
    }

    @Test func aNewTabPageInOneWorkspaceMapsOnlyItsRow() throws {
        let fixture = try Fixture()
        defer { fixture.feed.reset() }
        let store = fixture.services.machines.local.store
        #expect(fixture.listed.count >= Self.count, "the fixture lists every workspace")
        let opened = fixture.mapped { store.apply(snapshot: Self.tree(page: true)) }
        let page = try #require(store.workspaces.first { $0.key?.rawValue == Self.opened }?.screens.first?.panes.first?.tabs.last)
        #expect(SidebarBridge.newTabPages(fixture.services.agentTabs, in: store).contains(page.id), "the blank chat tab is a New Tab page")
        let closed = fixture.mapped { store.apply(snapshot: Self.tree()) }
        print("SIDEBAR-NEW-TAB-PASS n=\(Self.count) opened=\(opened) closed=\(closed)")
        #expect(opened == 1, "a New Tab page opened in one workspace mapped \(opened) of \(Self.count) rows")
        #expect(closed == 1, "a New Tab page closed in one workspace mapped \(closed) of \(Self.count) rows")
    }
}
