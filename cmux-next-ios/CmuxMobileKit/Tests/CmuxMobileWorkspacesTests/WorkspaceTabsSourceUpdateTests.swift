import CmuxMobileModel
import Foundation
import Observation
import Testing
@testable import CmuxMobileWorkspaces

// WorkspaceTabsSource and AgentSessionDirectory are iOS-only: these run in
// the iOS simulator test pass.
#if os(iOS)
import CmuxMobileAgentChat

/// verify/e2e-matrix.md #4 against the real source (review m3): building a
/// workspace screen's `WorkspaceTabsSource` and its pages must not write
/// anything a view read, or SwiftUI re-runs the update forever.
@MainActor @Suite(.serialized) struct WorkspaceTabsSourceUpdateTests {
    /// Every observed property a view could have read, the store's and the
    /// chat directory's.
    static func readAll(_ store: AppStore, _ sessions: AgentSessionDirectory) {
        _ = store.teams
        _ = store.workspaces
        _ = store.lastTabByWorkspace
        _ = store.macData
        _ = store.macConnection
        _ = store.pendingWorkspaceIDs
        _ = store.workspaceAliases
        _ = store.seenAt
        _ = store.focusOnOpenWorkspaceIDs
        for workspace in store.workspaces {
            for tab in workspace.tabs { _ = sessions.existingStore(id: tab.id) }
        }
    }

    /// Runs `evaluate` as SwiftUI updates a view: again while an observation
    /// installed before the run saw a change. `limit` means it never settled.
    static func updateCount(_ store: AppStore, _ sessions: AgentSessionDirectory, limit: Int = 20,
                            _ evaluate: () -> Void) -> Int {
        var runs = 0
        let dirty = SourceChanges()
        dirty.count = 1
        while dirty.count > 0, runs < limit {
            dirty.count = 0
            runs += 1
            withObservationTracking { readAll(store, sessions) } onChange: { dirty.count += 1 }
            evaluate()
        }
        return runs
    }

    /// What a workspace screen's body does: builds the source, reads its
    /// tabs, and builds each page (an agent tab's chat store included).
    static func buildScreen(_ store: AppStore, _ sessions: AgentSessionDirectory) {
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: sessions)
        _ = source.tabs
        _ = source.activeTabID
        guard let workspace = source.workspace else { return }
        for tab in workspace.tabs where tab.kind == .agent {
            _ = source.chatStore(tab, workspace)
            _ = source.surface(tab.id)
        }
    }

    @Test func buildingTheRealSourceSettlesInOneUpdate() {
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "gone"]))
        let sessions = AgentSessionDirectory()
        #expect(Self.updateCount(store, sessions) { Self.buildScreen(store, sessions) } == 1)
        // A workspace this phone just created (a focus request waiting).
        store.requestFocusOnOpen("ws-cmux")
        let fresh = AgentSessionDirectory()
        #expect(Self.updateCount(store, fresh) { Self.buildScreen(store, fresh) } == 1)
        #expect(store.wantsFocusOnOpen("ws-cmux"))
    }

    /// Review m2: the first read of an agent tab's chat caches it without
    /// telling the views that read the directory.
    @Test func cachingAChatNotifiesNobody() {
        let sessions = AgentSessionDirectory()
        let notified = SourceChanges()
        withObservationTracking { _ = sessions.existingStore(id: "t-claude") } onChange: { notified.count += 1 }
        let summary = AgentSessionSummary(id: "t-claude", name: "s", harness: "claude", agentName: "Claude",
                                          cwd: "~", workspaceTitle: "w", macName: "m", branch: nil, status: .idle)
        let first = sessions.store(for: summary)
        #expect(notified.count == 0)
        #expect(sessions.store(for: summary) === first)
        // Replacing a store (its session changed on the Mac) does tell them.
        sessions.invalidate(id: "t-claude")
        #expect(notified.count == 1)
        #expect(sessions.store(for: summary) !== first)
    }

    /// Sign-out: no chat stays loaded (notification previews save the loaded ones), and the next
    /// read builds a fresh store.
    @Test func signOutForgetsEveryChat() {
        let sessions = AgentSessionDirectory()
        let summary = AgentSessionSummary(id: "t-claude", name: "s", harness: "claude", agentName: "Claude",
                                          cwd: "~", workspaceTitle: "w", macName: "m", branch: nil, status: .idle, macID: "mac-1")
        let first = sessions.store(for: summary)
        let notified = SourceChanges()
        withObservationTracking { _ = sessions.existingStore(id: "t-claude", macID: "mac-1") } onChange: { notified.count += 1 }
        sessions.removeAll()
        #expect(notified.count == 1)
        #expect(sessions.loadedStores.isEmpty)
        #expect(sessions.existingStore(id: "t-claude", macID: "mac-1") == nil)
        #expect(sessions.store(for: summary) !== first)
    }

    /// Review m1: a page that used the focus request before the screen's
    /// `opened()` is not re-armed by it.
    @Test func openedConsumesWithoutReArmingFocus() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.requestFocusOnOpen("ws-cmux")
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory())
        #expect(source.focusOnOpen)
        source.pageAppeared(try! #require(source.activeTabID))
        #expect(!source.focusOnOpen)
        source.opened()
        #expect(!source.focusOnOpen)
        #expect(!store.wantsFocusOnOpen("ws-cmux"))
    }
}

/// Counts observation callbacks (synchronous on the main actor here).
final class SourceChanges: @unchecked Sendable {
    var count = 0
}
#endif
