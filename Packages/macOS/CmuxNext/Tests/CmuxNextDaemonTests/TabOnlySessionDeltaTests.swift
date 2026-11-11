@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// PR #40804: the daemon's `tab.update` (zoom, unread mark, attention mark, icon) publishes on `session.events` a delta
/// that holds ONE change, the tab's upsert. Before, the same batch also restated each workspace, screen, pane and tab.
/// The app must take that delta alone: the mirror holds the tab's new record and no other change, the tab's record
/// shows the value in the same turn, the reader of that tab is woken, and the readers of its sibling tab, its pane, its
/// screen, its workspace, the workspace list and the other workspace are not.
///
/// The tab record the mirror keeps is the value's `extra` only (`SessionWire.Entity.tabRecord`): zoom, back, forward,
/// icon, emulation, marked_unread, attention. A tab's name, title and pin come with the raw tree's events, not with
/// this delta, and the app keeps no cursor or revision of `session.events`: neither has a case here.
@MainActor
struct TabOnlySessionDeltaTests {
    static let target = ResourceID(rawValue: "tab_1_0")
    static let request = String(repeating: "a", count: 32)

    /// Two workspaces, each one screen with one pane of two tabs: tab `tab_<workspace>_<index>` is surface
    /// `workspace * 10 + index`.
    static func tree() -> DaemonTree {
        DaemonTree(workspaces: (1...2).map { workspace -> WorkspaceSnapshot in
            let base = UInt64(workspace) * 10
            let tabs = (0...1).map { index -> TabSnapshot in
                TabSnapshot(surface: SurfaceID(rawValue: base + UInt64(index)),
                            tabResourceID: ResourceID(rawValue: "tab_\(workspace)_\(index)"),
                            name: index == 0 ? "build \(workspace)" : nil, title: "shell \(workspace).\(index)", pinned: index == 1)
            }
            let pane = PaneSnapshot(id: PaneID(rawValue: base), resourceID: ResourceID(rawValue: "pane_\(workspace)"), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), resourceID: ResourceID(rawValue: "screen_\(workspace)"),
                                        layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: nil,
                                     resourceID: ResourceID(rawValue: "ws_\(workspace)"), name: "w\(workspace)", screens: [screen])
        })
    }

    /// The stream's first item: a record for each workspace, screen and tab of ``tree()``.
    static let snapshot: String = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"#
        + #""workspaces":[{"id":"ws_1","extra":{"agent_folder":"/tmp/one"}},{"id":"ws_2","extra":{"agent_folder":"/tmp/two"}}],"#
        + #""screens":[{"id":"screen_1","extra":{"pinned":true,"color":"blue"}},{"id":"screen_2","extra":{"color":"red"}}],"#
        + #""tabs":[{"id":"tab_1_0","extra":{"zoom":1.1,"icon":"star"}},{"id":"tab_1_1","extra":{"zoom":1.25,"marked_unread":true}},"#
        + #"{"id":"tab_2_0","extra":{"zoom":2,"icon":"bolt"}},{"id":"tab_2_1","extra":{"marked_unread":true}}],"#
        + #""extra":{"state":{}}}}}"#

    /// The delta #40804's daemon sends for one `tab.update` (`SessionDelta` of resource-operations-v2.json): the
    /// upsert of `tab_1_0` alone, with the tab's whole public value; `extra` is its `extra` object.
    static func delta(extra: String) -> String {
        #"{"type":"stream_item","item":{"kind":"delta","cursor":{"generation":"g1","revision":"42"},"previous_revision":"41","#
            + #""revision":"42","changes":[{"kind":"upsert","resource":"tab","id":"tab_1_0","value":{"id":"tab_1_0","#
            + #""pane_id":"pane_1","name":"build 1","index":0,"focused":true,"content_kind":"terminal","#
            + #""content_id":"term_1_0","extra":\#(extra)}}]}}"#
    }

    static func store() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        store.apply(.sessionState(try #require(SessionStreamItem.decode(Data(snapshot.utf8)))))
        return store
    }

    /// What a tab's record shows: the fields its tab record lays over it, then the tree's name, title and pin.
    struct Shown: Equatable {
        var zoom: Double?
        var icon: String?
        var markedUnread: Bool
        var attention: TabAttention?
        var name: String?
        var title: String
        var pinned: Bool
    }

    static func shown(_ tab: TabModel) -> Shown {
        Shown(zoom: tab.zoom, icon: tab.userIcon, markedUnread: tab.markedUnread, attention: tab.attention, name: tab.name,
              title: tab.titleText, pinned: tab.pinned)
    }

    /// Counts, by reader, the changes the tracked readers hear (one-shot tracking: a view reading it would redraw).
    @MainActor final class Wakes {
        var woken: [String: Int] = [:]

        func watch(_ reader: String, _ read: () -> Void) {
            withObservationTracking { read() } onChange: { MainActor.assumeIsolated { self.woken[reader, default: 0] += 1 } }
        }
    }

    /// Applies the delta whose tab value holds `extra` to a store that shows ``tree()`` and checks the mirror, the
    /// records and the wakes. `read` reads the field of the tab that `field` changes.
    private func check(_ field: String, extra: String, record: SessionStateMirror.TabRecord, read: (TabModel) -> Void) throws {
        let store = try Self.store()
        try #require(store.workspaces.count == 2)
        let first = store.workspaces[0], other = store.workspaces[1]
        let screen = try #require(first.screens.first), pane = try #require(screen.panes.first)
        let otherScreen = try #require(other.screens.first), otherPane = try #require(otherScreen.panes.first)
        let tab = try #require(store.tab(surface: SurfaceID(rawValue: 10)))
        let sibling = try #require(store.tab(surface: SurfaceID(rawValue: 11)))
        try #require(tab.resourceID == Self.target && pane.tabs.count == 2 && pane.tabs.first === tab && otherPane.tabs.count == 2)
        let before = try #require(store.session.mirror)
        try #require(before.tabs.count == 4 && before.screens.count == 2 && before.agentFolders.count == 2, "fixture: the snapshot's records")
        try #require(before.tabs[Self.target] != record, "fixture: the delta changes nothing")
        let tabs = pane.tabs + otherPane.tabs
        let shownBefore = tabs.map { Self.shown($0) }
        func frame() -> [String?] {
            [first.name, first.agentFolder, screen.color, screen.pinned.description,
             other.name, other.agentFolder, otherScreen.color, otherScreen.pinned.description]
        }
        let frameBefore = frame()

        let item = try #require(SessionStreamItem.decode(Data(Self.delta(extra: extra).utf8)))
        #expect(item == .delta([.tab(Self.target, record)]), "\(field): the line is not the tab's upsert alone")

        let wakes = Wakes()
        wakes.watch("tab") { read(tab) }
        wakes.watch("sibling tab") { _ = (Self.shown(sibling), sibling.showsUnread) }
        wakes.watch("pane") { _ = pane.tabs }
        wakes.watch("screen") { _ = (screen.panes, screen.pinned, screen.color) }
        wakes.watch("workspace") { _ = (first.screens, first.name, first.agentFolder) }
        wakes.watch("workspace list") { _ = store.workspaces }
        wakes.watch("other workspace") {
            _ = (other.screens, other.name, other.agentFolder, otherScreen.panes, otherScreen.pinned, otherScreen.color)
            for each in otherPane.tabs { _ = (Self.shown(each), each.showsUnread) }
        }

        store.apply(.sessionState(item))

        // The mirror: the tab's record is the delta's (a record with no field is no record), all else is as it was.
        var expected = before
        expected.tabs[Self.target] = record.isEmpty ? nil : record
        #expect(store.session.mirror == expected, "\(field): the mirror does not hold the tab's new record and no other change")
        // The records: the tab shows its record; its name, title and pin, and the three other tabs, stay.
        var shownAfter = shownBefore
        shownAfter[0].zoom = record.zoom
        shownAfter[0].icon = record.icon
        shownAfter[0].markedUnread = record.markedUnread
        shownAfter[0].attention = record.attention
        #expect(tabs.map { Self.shown($0) } == shownAfter, "\(field): the tab does not show its record, or another tab changed")
        #expect(store.workspaces.count == 2 && store.workspaces.first === first && store.workspaces.last === other)
        #expect(first.screens.count == 1 && first.screens.first === screen && screen.panes.count == 1 && screen.panes.first === pane)
        #expect(pane.tabs.count == 2 && pane.tabs.first === tab && pane.tabs.last === sibling)
        #expect(otherPane.tabs.count == 2 && otherScreen.panes.first === otherPane && other.screens.first === otherScreen)
        #expect(frame() == frameBefore, "\(field): a workspace's or a screen's state changed")
        // The wakes: the tab's reader, once; no reader of a record the delta does not name.
        #expect(wakes.woken == ["tab": 1], "\(field): the delta woke \(wakes.woken), not the tab's reader alone")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    @Test func aZoomAloneChangesTheTab() throws {
        try check("zoom", extra: #"{"zoom":1.5,"icon":"star"}"#, record: .init(zoom: 1.5, icon: "star")) { _ = $0.zoom }
    }

    @Test func anUnreadMarkAloneChangesTheTab() throws {
        try check("marked_unread", extra: #"{"zoom":1.1,"icon":"star","marked_unread":true}"#,
                  record: .init(zoom: 1.1, icon: "star", markedUnread: true)) { _ = $0.markedUnread }
    }

    @Test func anAttentionMarkAloneChangesTheTab() throws {
        let attention = #"{"reason":"Approve the plan","at_ms":1729000000000,"request_id":"\#(Self.request)"}"#
        let mark = TabAttention(reason: "Approve the plan", atMs: 1_729_000_000_000, requestID: Self.request)
        try check("attention", extra: #"{"zoom":1.1,"icon":"star","attention":\#(attention)}"#,
                  record: .init(zoom: 1.1, icon: "star", attention: mark)) { _ = $0.attention }
    }

    @Test func anIconAloneChangesTheTab() throws {
        try check("icon", extra: #"{"zoom":1.1,"icon":"flame"}"#, record: .init(zoom: 1.1, icon: "flame")) { _ = $0.userIcon }
    }

    /// The tab's last record field is cleared: its value has an empty `extra`, and the mirror drops the record.
    @Test func aClearedRecordAloneChangesTheTab() throws {
        try check("cleared", extra: "{}", record: .init()) { _ = $0.zoom }
    }
}
