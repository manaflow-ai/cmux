import Foundation
import Observation
import Testing
@testable import CmuxMobileModel

/// The Workspaces tab badge reads `attentionCount`. The Mac's tree changes the
/// workspaces several times a second while an agent works (status, titles);
/// the tab bar must only re-render when the count itself changes.
@MainActor
@Suite struct AttentionCountTests {
    final class Flag: @unchecked Sendable { var fired = false }

    static func workspace(_ id: String, mac: String = "m1", attention: Bool = false, title: String = "ws") -> Workspace {
        Workspace(id: id, macID: mac, title: title, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0),
                  needsAttention: attention)
    }

    func store(_ workspaces: [Workspace]) -> AppStore {
        AppStore(teams: [Team(id: "t", name: "T", macs: [MacDevice(id: "m1", name: "Mac", isOnline: true)])],
                 activeTeamID: "t", workspaces: workspaces, feed: [], tabMemory: .inMemory())
    }

    func notifies(_ store: AppStore, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { _ = store.attentionCount } onChange: { flag.fired = true }
        change()
        return flag.fired
    }

    @Test func countsTheActiveTeamsWorkspacesThatNeedAttention() {
        let store = store([Self.workspace("a", attention: true), Self.workspace("b"), Self.workspace("c", mac: "other", attention: true)])
        #expect(store.attentionCount == 1)
    }

    @Test func treeUpdatesThatKeepTheCountDoNotNotify() {
        let store = store([Self.workspace("a", attention: true), Self.workspace("b")])
        #expect(!notifies(store) { store.workspaces = [Self.workspace("a", attention: true, title: "renamed"), Self.workspace("b", title: "x")] })
        #expect(notifies(store) { store.workspaces = [Self.workspace("a"), Self.workspace("b")] })
        #expect(store.attentionCount == 0)
        #expect(notifies(store) { store.workspaces[1].needsAttention = true })
        #expect(store.attentionCount == 1)
    }
}
