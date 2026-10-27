import CmuxMobileModel
import Foundation
import Observation
import Testing
@testable import CmuxMobileWorkspaces

// WorkspaceTabsSource is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileAgentChat
import CmuxTabsKit

/// The tab grid's list (verify/listperf, tabs lane): the source publishes
/// `tabs` only when a field the kit shows changes, and rebuilds only the
/// tabs whose inputs changed, so a busy Mac or a streaming chat does not
/// re-run the tabs screen and every card.
@MainActor @Suite(.serialized) struct WorkspaceTabsSourceListTests {
    static func source(_ store: AppStore) -> WorkspaceTabsSource {
        WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory())
    }

    /// A publish that changes another workspace (or nothing the kit shows)
    /// rebuilds no tab and tells nobody who read `tabs` or `activeTabID`.
    @Test func anotherWorkspaceChangingRebuildsNothing() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let before = source.kitTabBuilds
        let tabs = source.tabs
        #expect(!tabs.isEmpty)
        let notified = SourceChanges()
        withObservationTracking {
            _ = source.tabs
            _ = source.activeTabID
        } onChange: { notified.count += 1 }
        let other = try #require(store.workspaces.first { $0.id != "ws-cmux" })
        store.workspaces = store.workspaces.map { ws in
            var ws = ws
            if ws.id == other.id { ws.lastActivityAt = Date().addingTimeInterval(60); ws.isWorking.toggle() }
            if ws.id == "ws-cmux" { ws.lastActivityAt = Date().addingTimeInterval(30) }
            return ws
        }
        // What the observation's hop does.
        source.refreshTabs()
        #expect(source.kitTabBuilds == before)
        #expect(notified.count == 0)
        #expect(source.tabs == tabs)
    }

    /// Renaming one tab rebuilds that tab only, and publishes the list once.
    @Test func renamingOneTabRebuildsOnlyIt() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let before = source.kitTabBuilds
        let target = try #require(source.tabs.last { $0.kind == .terminal })
        let notified = SourceChanges()
        withObservationTracking { _ = source.tabs } onChange: { notified.count += 1 }
        _ = store.renameTab(target.id, in: "ws-cmux", to: "Renamed")
        source.refreshTabs()
        #expect(source.kitTabBuilds == before + 1)
        #expect(notified.count == 1)
        #expect(source.tabs.first { $0.id == target.id }?.title == "Renamed")
    }

    /// A card reads its own tab's entry: another tab's change does not
    /// notify it.
    @Test func cardEntriesAreObservedPerTab() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let ids = source.tabs.map(\.id)
        #expect(ids.count >= 2)
        let first = try #require(source.entry(ids[0]))
        let notified = SourceChanges()
        withObservationTracking { _ = first.tab } onChange: { notified.count += 1 }
        _ = store.renameTab(ids[1], in: "ws-cmux", to: "Other")
        source.refreshTabs()
        #expect(notified.count == 0)
        _ = store.renameTab(ids[0], in: "ws-cmux", to: "Mine")
        source.refreshTabs()
        #expect(notified.count == 1)
    }

    /// Closing a tab: `tabs` drops it before `close` returns (the kit reads
    /// it at once for Safari's timing).
    @Test func removedTabLeavesTheListAtOnce() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let id = try #require(source.tabs.last?.id)
        _ = store.removeTab(id, from: "ws-cmux")
        source.refreshTabs()
        #expect(!source.tabs.contains { $0.id == id })
        #expect(source.entry(id) == nil)
    }
}
#endif
