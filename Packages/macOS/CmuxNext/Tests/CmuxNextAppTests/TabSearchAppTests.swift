import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextPalette
import Foundation
import Testing

/// Search Tabs over the App: the closed-tab change event fires once the
/// closed list is current, and `tabs.search` answers from the published
/// control snapshot off the main actor.
@MainActor
struct TabSearchAppTests {
    final class Seen {
        var entries: [[TabSearchEntry]] = []
    }

    /// A tab closed on the daemon: the source's change event comes after the
    /// closed list has it, so a reader sees it under Recently Closed and not
    /// under Open Tabs in the same read.
    @Test func aClosedTabIsInTheClosedListWhenTheChangeEventArrives() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.activeDaemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = store.apply(.connected(identity, generationChanged: false))
        store.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp/a"),
                                                             ReopenClosedTabTests.tab(2, "b", cwd: "/tmp/b")]))
        await ReopenClosedTabTests.settle { false }
        let source = AppTabSearchSource(services: services)
        let seen = Seen()
        let stream = source.changes()
        let listener = Task { @MainActor in
            for await _ in stream {
                seen.entries.append(source.tabSearchEntries())
                if seen.entries.last?.contains(where: \.isClosed) == true { return }
            }
        }
        store.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp/a")]))
        await ReopenClosedTabTests.settle { seen.entries.last?.contains(where: \.isClosed) == true }
        listener.cancel()
        let atEvent = try #require(seen.entries.last)
        #expect(atEvent.contains { $0.isClosed && $0.id.hasSuffix("/tab_b") && $0.cwd == "/tmp/b" })
        #expect(!atEvent.contains { !$0.isClosed && $0.id == "tab_b" })
        #expect(atEvent.contains { !$0.isClosed && $0.id == "tab_a" })
    }

    @Test func tabsSearchIsASnapshotMethod() throws {
        let method = try #require(TabSearchControl.methods().first { $0.name == "tabs.search" })
        #expect(method.lane == .snapshot)
    }

    /// The snapshot mapping and ranking run without the main actor.
    @Test func snapshotEntriesRankOffTheMainActor() async throws {
        var topology = ControlTopology()
        topology.workspaces = [ControlWorkspaceInfo(id: "ws", handle: "1", name: "api", screens: [
            ControlScreenInfo(id: "s", handle: "4", panes: [
                ControlPaneInfo(id: "p", handle: "3", tabs: [
                    ControlTabInfo(id: "tab_x", surface: "1", kind: "browser", title: "Pull requests", url: "https://github.com/x/y"),
                    ControlTabInfo(id: "tab_y", surface: "2", kind: "terminal", title: "zsh", cwd: "/src/web"),
                ], tabGroups: []),
            ]),
        ])]
        topology.focus = ControlFocus(tabID: "tab_y")
        let facts = ControlTabSearchFacts(closed: [ControlClosedTab(id: "local/tab_z", kind: "terminal", title: "htop",
                                                                    closedAt: Date(timeIntervalSince1970: 1))])
        let ids = await Task.detached {
            TabSearchRanker().search(TabSearchEntries.entries(topology, facts), query: "", now: Date()).map(\.row.entry.id)
        }.value
        #expect(ids == ["tab_y", "tab_x", "local/tab_z"])
        let github = await Task.detached {
            TabSearchRanker().search(TabSearchEntries.entries(topology, facts), query: "github", now: Date()).first?.row.entry.id
        }.value
        #expect(github == "tab_x")
    }
}
