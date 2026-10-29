import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct AttentionSnapshotTests {
    private static func connectedStore() throws -> DaemonStore {
        let store = DaemonStore()
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(
            #"{"app":"cmux-tui","protocol":1,"session":"attention-test","generation":"g1","capabilities":["state-resources-v1"]}"#.utf8))
        store.identity = identity
        store.connectionState = .connected(identity)
        return store
    }

    private static func tree(_ store: DaemonStore) {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_test", title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Test", screens: [screen])]))
    }

    private static func state(_ store: DaemonStore, mark: UInt64?) {
        var mirror = SessionStateMirror()
        if let mark { mirror.tabs["tab_test"] = .init(attention: .init(reason: "Sign in", atMs: mark)) }
        store.session.apply(.snapshot(mirror), in: store)
    }

    private static func mark(_ store: DaemonStore, at: UInt64) {
        store.session.apply(.delta([.tab("tab_test", .init(attention: .init(reason: "Sign in again", atMs: at)))]), in: store)
    }

    @Test(arguments: [false, true])
    func lateSnapshotsBaselineButFirstNewRequestPosts(stateFirst: Bool) throws {
        _ = NSApplication.shared
        let store = try Self.connectedStore()
        var baseline = AttentionTabsWatch.SnapshotBaseline()
        let service = NotificationCenterService()
        service.desktopPostingEnabled = false
        func apply() -> Set<String> {
            let snapshot = AttentionTabsWatch.Snapshot(machine: "local", store: store)
            let eligible = baseline.eligibleRequests([snapshot])
            service.attentionMarksChanged(snapshot.items, eligibleRequests: eligible)
            return eligible
        }
        #expect(apply().isEmpty)
        if stateFirst { Self.state(store, mark: 1_000) } else { Self.tree(store) }
        #expect(apply().isEmpty, "neither partial stream is a baseline")
        if stateFirst { Self.tree(store) } else { Self.state(store, mark: 1_000) }
        #expect(apply().isEmpty, "pre-existing marks must not post at startup")
        let before = service.attentionSeen
        Self.mark(store, at: 2_000)
        let eligible = apply()
        let current = AttentionTabsWatch.Snapshot(machine: "local", store: store).items
        #expect(AttentionBannerLifecycle.attentionChanges(previous: before, current: current).post.map(\.tabId) == Array(eligible))
        #expect(eligible.count == 1, "the first new request after baseline was swallowed")
    }

    @Test func emptyReadySnapshotAndOfflineRemoteDoNotSwallowFirstLocalRequest() throws {
        let local = try Self.connectedStore(), offline = DaemonStore()
        Self.tree(local)
        var baseline = AttentionTabsWatch.SnapshotBaseline()
        func snapshots() -> [AttentionTabsWatch.Snapshot] {
            [.init(machine: "local", store: local), .init(machine: "remote", store: offline)]
        }
        let before = snapshots()
        #expect(baseline.eligibleRequests(before).isEmpty)
        Self.state(local, mark: nil)
        let ready = snapshots()
        #expect(before != ready, "readiness changes must survive ObservationStream equality even for empty lists")
        #expect(baseline.eligibleRequests(ready).isEmpty)
        Self.mark(local, at: 1_000)
        #expect(baseline.eligibleRequests(snapshots()).count == 1, "an offline remote suppressed a local request")
    }

    @Test func failedReconnectAndStreamReplayDoNotRepostRetainedMarks() throws {
        let store = try Self.connectedStore()
        Self.tree(store)
        Self.state(store, mark: 1_000)
        var baseline = AttentionTabsWatch.SnapshotBaseline()
        func eligible() -> Set<String> { baseline.eligibleRequests([.init(machine: "local", store: store)]) }
        #expect(eligible().isEmpty)
        Self.mark(store, at: 2_000)
        #expect(eligible().count == 1)
        store.connectionEpoch += 1
        store.session.connected(servesStateResources: true)
        Self.tree(store)
        store.session.apply(.ended(reason: "stream unavailable"), in: store)
        #expect(store.session.mirror != nil && store.session.known, "fixture retains the prior mirror after refusal")
        #expect(!AttentionTabsWatch.Snapshot(machine: "local", store: store).ready)
        #expect(eligible().isEmpty)
        Self.state(store, mark: 3_000)
        #expect(eligible().isEmpty, "reconnect snapshot posted a retained request")
        Self.mark(store, at: 4_000)
        #expect(eligible().count == 1)
        // Even when observation coalesces the stream end and reopen, a new snapshot generation
        // baselines quietly without relying on observing the transient not-ready state.
        store.session.apply(.ended(reason: "gap"), in: store)
        Self.state(store, mark: 5_000)
        #expect(eligible().isEmpty, "same-connection replay posted as a fresh request")
    }

    @Test func replacementStoreWithTheSameMachineAndEpochGetsItsOwnBaseline() throws {
        let first = try Self.connectedStore(), replacement = try Self.connectedStore()
        Self.tree(first)
        Self.state(first, mark: nil)
        Self.tree(replacement)
        Self.state(replacement, mark: 1_000)
        var baseline = AttentionTabsWatch.SnapshotBaseline()
        #expect(baseline.eligibleRequests([.init(machine: "local", store: first)]).isEmpty)
        #expect(baseline.eligibleRequests([.init(machine: "local", store: replacement)]).isEmpty,
                "a replacement store reused the old store's baseline")
        Self.mark(replacement, at: 2_000)
        #expect(baseline.eligibleRequests([.init(machine: "local", store: replacement)]).count == 1)
    }

}
