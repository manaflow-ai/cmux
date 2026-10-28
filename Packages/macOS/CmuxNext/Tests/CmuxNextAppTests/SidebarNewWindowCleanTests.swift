@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/26632: every new window (and every new Space) opens clean. A window kept
/// listing the pins of the other windows: a Pinned group whose workspaces had closed, a pinned tab, a pinned page, an
/// empty workspace group. Each pin, group and link now belongs to the window it was made in; a new window owns none.
@MainActor @Suite struct SidebarNewWindowCleanTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let pinned = "sec_pinned"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// Window A's sidebar: Pinned holds group `itm_gs` (its one workspace `ws-4` closed), a pinned tab `itm_tab` and a
    /// pinned page `itm_url`; This Mac lists `ws-1` and an empty group `itm_ge` with a link `itm_link` after it.
    /// `extra` adds Pinned items made later.
    static func projection(extra: [(String, SidebarDocBody)] = []) -> SidebarDocProjection {
        var items: [String: SidebarDocItem] = [
            "itm_gs": SidebarDocItem(id: "itm_gs", section: pinned, body: .group(name: "Saved", color: nil, icon: nil, collapsed: false)),
            "itm_4": SidebarDocItem(id: "itm_4", section: pinned, parent: "itm_gs", body: .workspace(ref("ws-4"))),
            "itm_tab": SidebarDocItem(id: "itm_tab", section: pinned, body: .tab("tab_1")),
            "itm_url": SidebarDocItem(id: "itm_url", section: pinned, body: .url("https://cmux.com", title: "cmux")),
            "itm_home": SidebarDocItem(id: "itm_home", section: pinned, body: .app("cmux/home")),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_ge": SidebarDocItem(id: "itm_ge", section: machine, body: .group(name: "Empty", color: nil, icon: nil, collapsed: false)),
            "itm_link": SidebarDocItem(id: "itm_link", section: machine, body: .url("https://example.com", title: "Example")),
        ]
        var rows = [
            SidebarDocRow(key: "itm_home", kind: "item", section: pinned, item: "itm_home"),
            SidebarDocRow(key: "itm_gs", kind: "group", section: pinned, item: "itm_gs"),
            SidebarDocRow(key: "itm_4", kind: "item", section: pinned, parent: "itm_gs", depth: 1, item: "itm_4", dimmed: true, ref: ref("ws-4")),
            SidebarDocRow(key: "itm_tab", kind: "item", section: pinned, item: "itm_tab"),
            SidebarDocRow(key: "itm_url", kind: "item", section: pinned, item: "itm_url"),
        ]
        for (id, body) in extra {
            items[id] = SidebarDocItem(id: id, section: pinned, body: body)
            rows.append(SidebarDocRow(key: id, kind: "item", section: pinned, item: id))
        }
        rows += [
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_ge", kind: "group", section: machine, item: "itm_ge"),
            SidebarDocRow(key: "itm_link", kind: "item", section: machine, item: "itm_link"),
        ]
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: items)
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func drag(hidden: Set<String>) -> SidebarDocDrag {
        var drag = SidebarDocDrag(item: { key in
            if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
            return nil
        }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })
        drag.listedElsewhere = { _ in false }
        drag.hiddenItems = hidden
        return drag
    }

    static let thisMac = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// What a window's sidebar lists besides workspace rows: its groups and links, and its band items.
    /// `grouped`: workspaces this window lists in group `itm_ge`.
    static func listed(_ projection: SidebarDocProjection, window: String, bands: WindowBandOwnership, workspaces: [String],
                       grouped: [String] = []) -> [String] {
        let hidden = bands.hidden(in: window)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let live = [SidebarSection(kind: .machine(thisMac), nodes: workspaces.map { .workspace(ws($0)) }
            + [.group(SidebarGroup(id: GroupID("itm_ge"), name: "Empty", workspaces: grouped.map(ws)))])]
        let rows = projection.arrange(live, drag: drag(hidden: hidden)).flatMap(\.nodes).compactMap { node -> String? in
            switch node {
            case .workspace: nil
            case .group(let group): group.id.rawValue
            case .item(let item): item.id
            }
        }
        let band = projection.layout.withoutItems(where: { hidden.contains($0.id.rawValue) }).sections.flatMap(\.items).map(\.id.rawValue)
        return rows + band
    }

    /// Window A, then a new window B (A's pins made before it opened): B lists none of A's pins, A keeps them all.
    @Test func aNewWindowListsNoneOfTheOtherWindowsPins() {
        let projection = Self.projection()
        var bands = WindowBandOwnership()
        bands.adopt(projection.windowItems, registered: ["A"], front: "A") { _ in nil }
        // Cmd-Shift-N: B registers and comes to the front; the document did not change.
        bands.adopt(projection.windowItems, registered: ["A", "B"], front: "B") { _ in nil }
        #expect(Self.listed(projection, window: "B", bands: bands, workspaces: ["ws-2"]) == ["itm_home"],
                "the new window lists another window's pins: \(Self.listed(projection, window: "B", bands: bands, workspaces: ["ws-2"]))")
        #expect(Set(Self.listed(projection, window: "A", bands: bands, workspaces: ["ws-1"]))
            == ["itm_gs", "itm_ge", "itm_link", "itm_home", "itm_tab", "itm_url"])
    }

    /// A pin made in B stays in B; a group holding a workspace B lists shows in B whoever made it.
    @Test func pinsStayInTheWindowTheyWereMadeIn() {
        var bands = WindowBandOwnership()
        bands.adopt(Self.projection().windowItems, registered: ["A"], front: "A") { _ in nil }
        let later = Self.projection(extra: [("itm_url_b", .url("https://manaflow.com", title: nil))])
        bands.adopt(later.windowItems, registered: ["A", "B"], front: "B") { _ in nil }
        #expect(bands.owner(of: "itm_url_b") == "B")
        #expect(!Self.listed(later, window: "A", bands: bands, workspaces: ["ws-1"]).contains("itm_url_b"))
        #expect(Self.listed(later, window: "B", bands: bands, workspaces: ["ws-2"]) == ["itm_home", "itm_url_b"])
        // A's group with a workspace B lists (moved there) lists in B with it.
        #expect(Self.listed(later, window: "B", bands: bands, workspaces: ["ws-2"], grouped: ["ws-9"]).contains("itm_ge"))
    }

    /// Ownership survives a relaunch in the window records; a record from an older build owns nothing, so its
    /// window's pins go to the front window once, and a window that is gone leaves its pins to the front window.
    @Test func ownershipIsSavedPerWindowAndOrphansGoToTheFrontWindow() throws {
        var a = WindowRecord(id: "A")
        a.bandItems = ["itm_gs", "itm_tab"]
        let legacy = WindowRecord(id: "L")
        let decoded = try JSONDecoder().decode([WindowRecord].self, from: JSONEncoder().encode([a, legacy]))
        #expect(decoded.map(\.bandItems) == [["itm_gs", "itm_tab"], nil])
        var bands = WindowBandOwnership(saved: decoded.map { ($0.id, $0.bandItems) })
        bands.adopt(Self.projection().windowItems, registered: ["A", "L"], front: "L") { _ in nil }
        #expect(bands.items(of: "A") == ["itm_gs", "itm_tab"])
        #expect(bands.items(of: "L") == ["itm_ge", "itm_link", "itm_url"])
        bands.adopt(Self.projection().windowItems, registered: ["L"], front: "L") { _ in nil }
        #expect(bands.items(of: "L") == ["itm_ge", "itm_gs", "itm_link", "itm_tab", "itm_url"])
    }

    /// A pin goes to the window it was made in, even when another window is in front (a drop on a window that is
    /// not key, a sidebar's own menu); it keeps that owner while it leaves the document and comes back (Undo, a
    /// move into a group and out); an incognito window's pins never go to a normal window.
    @Test func aPinGoesToTheActingWindowAndKeepsItsOwner() {
        let base = Self.projection(), later = Self.projection(extra: [("itm_url_a", .url("https://manaflow.com", title: nil))])
        var bands = WindowBandOwnership()
        bands.adopt(base.windowItems, registered: ["A", "B"], front: "A") { _ in nil }
        bands.adopt(later.windowItems, registered: ["A", "B"], acting: "A", front: "B") { _ in nil }
        #expect(bands.owner(of: "itm_url_a") == "A")
        bands.adopt(base.windowItems, registered: ["A", "B"], front: "B") { _ in nil } // removed (or nested)
        bands.adopt(later.windowItems, registered: ["A", "B"], front: "B") { _ in nil } // back (Undo)
        #expect(bands.owner(of: "itm_url_a") == "A")
        #expect(bands.items(of: "A").contains("itm_url_a"))
        var incognito = WindowBandOwnership()
        incognito.adopt(later.windowItems, registered: ["A", "I"], incognito: ["I"], acting: "I", front: "A") { _ in nil }
        incognito.adopt(later.windowItems, registered: ["A"], front: "A") { _ in nil } // the incognito window closed
        #expect(incognito.items(of: "A").isEmpty, "a normal window took the incognito window's pins: \(incognito.items(of: "A"))")
        #expect(incognito.hidden(in: "A").contains("itm_url_a"))
    }

    /// Another window's empty Pinned group stays out even when the live rows carry it (a group with no open member
    /// passes the membership filter), and a nested group this window lists a workspace of keeps its parent header.
    @Test func anEmptyBandGroupOfAnotherWindowStaysOutAndANestedGroupKeepsItsParent() {
        var bands = WindowBandOwnership()
        bands.adopt(Self.projection().windowItems, registered: ["A", "B"], front: "A") { _ in nil }
        let live = [SidebarSection(kind: .machine(Self.thisMac), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-2"), title: "ws-2")),
            .group(SidebarGroup(id: GroupID("itm_gs"), name: "Saved", workspaces: [])),
        ])]
        let arranged = Self.projection().arrange(live, drag: Self.drag(hidden: bands.hidden(in: "B")))
        let groups = arranged.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } }
        #expect(!groups.contains("itm_gs"), "B lists A's Pinned group: \(groups)")

        // A's Pinned "Projects" > "Foo"; Foo's workspace moved to B.
        let pinned = Self.pinned, machine = Self.machine
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            machine: SidebarDocSection(id: machine, kind: .machine(session: Self.session)),
        ], items: [
            "itm_gp": SidebarDocItem(id: "itm_gp", section: pinned, body: .group(name: "Projects", color: nil, icon: nil, collapsed: false)),
            "itm_gf": SidebarDocItem(id: "itm_gf", section: pinned, parent: "itm_gp", body: .group(name: "Foo", color: nil, icon: nil, collapsed: false)),
            "itm_5": SidebarDocItem(id: "itm_5", section: pinned, parent: "itm_gf", body: .workspace(Self.ref("ws-5"))),
        ])
        let nested = SidebarDocProjection(rows: [
            SidebarDocRow(key: "itm_gp", kind: "group", section: pinned, item: "itm_gp"),
            SidebarDocRow(key: "itm_gf", kind: "group", section: pinned, parent: "itm_gp", depth: 1, item: "itm_gf"),
            SidebarDocRow(key: "itm_5", kind: "item", section: pinned, parent: "itm_gf", depth: 2, item: "itm_5", ref: Self.ref("ws-5")),
        ], records: records, revision: 1)
        var owners = WindowBandOwnership()
        owners.adopt(nested.windowItems, registered: ["A", "B"], front: "A") { _ in nil }
        var foo = SidebarGroup(id: GroupID("itm_gf"), name: "Foo", workspaces: [SidebarWorkspace(id: WorkspaceID("ws-5"), title: "ws-5")])
        foo.parent = GroupID("itm_gp")
        let inB = nested.arrange([SidebarSection(kind: .machine(Self.thisMac), nodes: [.group(foo)])], drag: Self.drag(hidden: owners.hidden(in: "B")))
        let shown = inB.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } }
        #expect(Set(shown) == ["itm_gp", "itm_gf"], "groups listed in B: \(shown)")
    }
}
