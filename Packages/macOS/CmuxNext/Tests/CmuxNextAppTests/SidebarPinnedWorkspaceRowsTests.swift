import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence, as relayed 2026-10-21: the pin symbol shows only when it is turned on in the row's ⋮ menu,
/// so no empty pin by default. Leo 2026-10-21: "the pinned thing the existing version is WEIRD it should
/// just be on the sidebar instead of to teh left of it".
///
/// An unpinned workspace row draws no pin glyph, at rest or on hover, at any density (the expanded row's
/// hover pin is gone). A pinned workspace is a normal workspace row in a Pinned area at the top of the
/// list, with the pin glyph; Pinned draws no tile for it. Unpin (the ⋮ menu's Unpin Workspace, which runs
/// the document's `unpin`) puts the row back in its machine list without the glyph.
@MainActor @Suite(.serialized)
struct SidebarPinnedWorkspaceRowsTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let pinned = SidebarDocStore.pinnedSection

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    // MARK: The document's Pinned area

    /// Pinned: workspace `ws-pin` (live), a link, workspace `ws-gone` (closed). This Mac: loose `ws-1`,
    /// group `gm` with `ws-2` pinned in the group and `ws-3`.
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top, look: .builtIn, arrangement: .grid),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_pin": SidebarDocItem(id: "itm_pin", section: pinned, body: .workspace(ref("ws-pin"))),
            "itm_link": SidebarDocItem(id: "itm_link", section: pinned, body: .url("https://example.com/docs", title: "Docs")),
            "itm_gone": SidebarDocItem(id: "itm_gone", section: pinned, body: .workspace(ref("ws-gone")), label: "Old notes"),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "Work", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2")), pinnedInGroup: true),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, parent: "itm_gm", body: .workspace(ref("ws-3"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_pin", kind: "item", section: pinned, item: "itm_pin", ref: ref("ws-pin")),
            SidebarDocRow(key: "itm_link", kind: "item", section: pinned, item: "itm_link"),
            SidebarDocRow(key: "itm_gone", kind: "item", section: pinned, item: "itm_gone", dimmed: true, ref: ref("ws-gone")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_3", ref: ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// The bridge's mapping of This Mac (`SidebarDocSections`): its rows, the pinned workspace among them.
    static func raw() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(ws("ws-1")),
            .group(SidebarGroup(id: GroupID("itm_gm"), name: "Work", workspaces: [ws("ws-2"), ws("ws-3")])),
            .workspace(ws("ws-pin")),
        ])]
    }

    static func workspaces(_ section: SidebarSection) -> [SidebarWorkspace] {
        section.nodes.flatMap { node -> [SidebarWorkspace] in
            switch node {
            case .workspace(let workspace): [workspace]
            case .group(let group): group.workspaces
            case .item: []
            }
        }
    }

    @Test func aPinnedWorkspaceIsNoTileInPinned() throws {
        let projection = Self.projection()
        let section = try #require(projection.layout.section(LayoutSectionID(Self.pinned)), "no Pinned section")
        #expect(!section.items.contains { $0.ref.kind == LayoutItemRef.workspaceKind },
                "Pinned draws a workspace tile: \(section.items.map(\.ref))")
        #expect(section.items.map(\.id.rawValue) == ["itm_link"], "the link stays in Pinned's own arrangement")
        #expect(projection.pinnedWorkspaces.map(\.item) == ["itm_pin", "itm_gone"])
        #expect(projection.pinnedItems == ["itm_pin", "itm_gone", "itm_2"])
    }

    @Test func aPinnedWorkspaceListsAsARowAtTheTopOfTheList() throws {
        let arranged = Self.projection().arrange(Self.raw(), drag: Self.drag)
        let pinnedAt = try #require(arranged.firstIndex { $0.id == .custom(Self.pinned) }, "no Pinned area in the list")
        let machineAt = try #require(arranged.firstIndex { $0.machine != nil })
        #expect(pinnedAt < machineAt, "the Pinned area is not above the machine list")
        let area = arranged[pinnedAt]
        guard case .workspace(let row)? = area.nodes.first else {
            Issue.record("Pinned's first node is not a workspace row: \(area.nodes)")
            return
        }
        #expect(row.id == WorkspaceID("ws-pin") && row.pinned, "the pinned row does not draw its pin")
        // A closed pinned workspace has no live row: its stored name lists as an item row, never a tile.
        guard case .item(let closed)? = area.nodes.dropFirst().first else {
            Issue.record("the closed pinned workspace does not list: \(area.nodes)")
            return
        }
        #expect(closed.id == "itm_gone" && closed.title == "Old notes")
        let machineRows = Self.workspaces(arranged[machineAt])
        #expect(!machineRows.contains { $0.id == WorkspaceID("ws-pin") }, "the pinned workspace lists twice")
        #expect(machineRows.first { $0.id == WorkspaceID("ws-2") }?.pinned == true, "a member pinned in its group draws no pin")
        for id in ["ws-1", "ws-3"] {
            #expect(machineRows.first { $0.id == WorkspaceID(id) }?.pinned == false, "\(id) is not pinned but draws a pin")
        }
        // Arranging again (a fold passes the shown list back) changes nothing.
        #expect(Self.projection().arrange(arranged, drag: Self.drag) == arranged)
    }

    @Test func theBridgeMapsAPinnedWorkspaceWithItsMachine() {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ["ws-pin", "ws-1", "ws-2", "ws-3"].enumerated().map { index, id in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id), name: id)
        }))
        let sections = SidebarDocSections().sections(Self.projection(), session: Self.session, workspaces: store.workspaces)
        let names = sections.flatMap(\.workspaces).map(\.displayName)
        #expect(names.filter { $0 == "ws-pin" }.count == 1, "the pinned workspace is not mapped once: \(names)")
    }

    // MARK: Unpin through the document

    /// The home daemon's document: Pinned holds `w_pin`; This Mac holds `w_one`.
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_pinned", "kind": {"type": "pinned"}},
                  {"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}],
     "items": [
       {"id": "w_pin", "section": "sec_pinned", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "pin"}}},
       {"id": "w_one", "section": "sec_m_s1", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "one"}}}
     ]}
    """.utf8)

    @Test func unpinPutsTheRowBackInItsMachineListWithoutItsPin() async throws {
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: Self.document))
        try #require(store.isSupported, "this build has no sidebar mirror")
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        let live = [SidebarDocWorkspaceRef(sessionID: "s1", workspaceID: "pin"), SidebarDocWorkspaceRef(sessionID: "s1", workspaceID: "one")]
        let before = try #require(store.projection(live: live))
        #expect(before.pinnedWorkspaces.map(\.item) == ["w_pin"])
        #expect(before.pinnedItems == ["w_pin"])

        // The ⋮ menu's Unpin Workspace on the document (`PinCommands.setWorkspacePinned`): the mirror shows it at once.
        store.unpin(["w_pin"], title: "Unpin Workspace")
        let after = try #require(store.projection(live: live))
        #expect(after.pinnedWorkspaces.isEmpty, "the workspace still lists in Pinned")
        #expect(after.pinnedItems.isEmpty, "the unpinned row still draws its pin")
        let listed = (after.machines["s1"] ?? []).compactMap { node -> String? in
            if case let .workspace(_, item) = node { item } else { nil }
        }
        #expect(listed.contains("w_pin"), "the unpinned workspace is not back in its machine list: \(listed)")
    }

    // MARK: The row's pin glyph

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// A sidebar listing `nodes` in one machine section, every row wired as the App wires it (the row menu
    /// and the pin hook), at `expanded` density, in a window on screen.
    static func sidebar(_ nodes: [SidebarNode], pinnedArea: [SidebarNode] = [], expanded: Bool) -> (SidebarView, NSWindow) {
        var sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)]
        if !pinnedArea.isEmpty { sections.insert(SidebarSection(kind: .pinned, nodes: pinnedArea), at: 0) }
        let model = SidebarModel(sections: sections)
        model.expanded = expanded
        // The App's pin hook (`SidebarWorkspacePins`): it offered the old hover pin.
        model.workspacePin = (isPinned: { _ in false }, toggle: { _ in })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.contextMenuProvider = { _ in NSMenu() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// The row's shown pin views (a pin glyph or a pin control), by their accessibility identifier.
    static func shownPins(_ row: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { sub -> [NSView] in
                guard !sub.isHidden, sub.alphaValue > 0 else { return [] }
                let own = sub.accessibilityIdentifier().hasSuffix(".pin") && sub.frame.width > 0 ? [sub] : []
                return own + walk(sub)
            }
        }
        return walk(row)
    }

    static func settle(_ row: WorkspaceRowView, hovered: Bool) {
        row.isHovered = hovered
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
    }

    @Test(.enabled("a window with no screen lays no row out") { await Self.hasDisplay() }, arguments: [false, true])
    func anUnpinnedRowDrawsNoPinAtRestOrOnHover(expanded: Bool) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (sidebar, window) = Self.sidebar([.workspace(Self.ws("ws-loose"))], expanded: expanded)
        defer { window.orderOut(nil) }
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws-loose"))] as? WorkspaceRowView)
        for hovered in [false, true, false] {
            Self.settle(row, hovered: hovered)
            #expect(Self.shownPins(row).isEmpty, "an unpinned row draws a pin (hovered: \(hovered), expanded: \(expanded))")
        }
    }

    @Test(.enabled("a window with no screen lays no row out") { await Self.hasDisplay() }, arguments: [false, true])
    func aPinnedRowDrawsItsPinAtRestAndOnHover(expanded: Bool) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        var pinned = Self.ws("ws-pinned")
        pinned.pinned = true
        let (sidebar, window) = Self.sidebar([.workspace(Self.ws("ws-loose"))], pinnedArea: [.workspace(pinned)], expanded: expanded)
        defer { window.orderOut(nil) }
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws-pinned"))] as? WorkspaceRowView)
        let loose = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws-loose"))] as? WorkspaceRowView)
        #expect(row.frame.minY < loose.frame.minY, "the pinned row is not above the list's rows")
        for hovered in [false, true] {
            Self.settle(row, hovered: hovered)
            let pins = Self.shownPins(row)
            #expect(pins.count == 1, "a pinned row draws \(pins.count) pins (hovered: \(hovered), expanded: \(expanded))")
            if let pin = pins.first { #expect(row.bounds.contains(pin.frame), "the pin \(pin.frame) is outside its row \(row.bounds)") }
        }
        #expect(row.accessibilityLabel()?.contains(Strings.pinned) == true, "VoiceOver does not hear that the row is pinned")
    }
}
