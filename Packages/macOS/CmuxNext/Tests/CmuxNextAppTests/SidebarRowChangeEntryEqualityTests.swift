import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// SIDEBAR ROW CHANGE stage 2: `SidebarModel.apply(_:)` takes ONE loose workspace row's change as its input
/// (`SidebarLooseRowChange`, as Chromium's `TabStripModelChange`), with no read of the other rows. It must show
/// exactly what `SidebarModel.setSections` shows for the same rows without the row, or with it, and refuse (false,
/// nothing changed) when it can not prove that; the caller then sets the sections.
///
/// The property: two models made the same way; a random loose row goes out or comes in; one model gets the full set,
/// the twin gets the entry (the full set after a refusal). Rows, revisions, the list's splice records, group lookups,
/// row places and the selection must be equal after each step, for several steps in a row (the entry keeps the
/// model's indexes itself). A world that no refusal rule names ("plain") must take the entry at every step.
/// The same holds while a sidebar document arranges the list and keeps the machine list's order (the real app).
///
///     swift test --filter SidebarRowChangeEntryEqualityTests
@MainActor @Suite struct SidebarRowChangeEntryEqualityTests {
    typealias Random = ClosingPanesRandom

    static let seeds = 600
    static let stepsPerSeed = 4
    static let hiddenRef = LayoutItemRef.app("rc/hidden")
    static let shownRef = LayoutItemRef.app("rc/shown")

    /// One seed's rows and the model state beside them.
    struct World {
        var sections: [SidebarSection]
        var filter = ""
        var hidden: Set<LayoutItemRef> = []
        var collapsed: Set<SectionID> = []
        var active: WorkspaceID?
        /// A workspace is listed twice.
        var repeats = false
        /// The hidden items take a node out of the list: the model's nodes are not at the caller's places.
        var hidesANode = false
        /// The last workspace number used.
        var serial = 0
        /// No refusal rule of the entry names this world: no filter, each workspace listed once, no hidden node.
        var plain: Bool { filter.isEmpty && !repeats && !hidesANode }
    }

    static func workspace(_ n: Int, _ r: inout Random) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("rc-\(n)"), title: "workspace \(n)")
        if r.chance(0.15) { ws.taskStatus = .done }
        return ws
    }

    /// 1 to 3 sections of loose rows, groups (some collapsed, some a subgroup of the one before), document items and
    /// Done rows; then a filter, hidden items, a collapsed section, a workspace listed twice, a selection.
    static func world(_ r: inout Random) -> World {
        var world = World(sections: [])
        let kinds: [SidebarSection.Kind] = [
            .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
            .custom(SidebarCustomSection(id: "rc-sec-a", title: "A")), .custom(SidebarCustomSection(id: "rc-sec-b", title: "B")),
        ]
        var groups = 0
        var loose: [SidebarWorkspace] = []
        for kind in kinds.prefix(Int(r.int(1 ... 3))) {
            var nodes: [SidebarNode] = []
            var parent: GroupID?
            for _ in 0 ..< Int(r.int(0 ... 9)) {
                switch r.int(0 ... 9) {
                case 0, 1:
                    groups += 1
                    var members: [SidebarWorkspace] = []
                    for _ in 0 ..< Int(r.int(0 ... 3)) {
                        world.serial += 1
                        members.append(workspace(world.serial, &r))
                    }
                    var group = SidebarGroup(id: GroupID("rc-g\(groups)"), name: "group \(groups)", isCollapsed: r.chance(0.3), workspaces: members)
                    if let parent, r.chance(0.5) { group.parent = parent }
                    parent = group.id
                    nodes.append(.group(group))
                case 2:
                    world.serial += 1
                    nodes.append(.item(SidebarListItem(id: "rc-item-\(world.serial)", ref: r.chance(0.5) ? hiddenRef : shownRef, title: "item \(world.serial)")))
                default:
                    world.serial += 1
                    let ws = workspace(world.serial, &r)
                    loose.append(ws)
                    nodes.append(.workspace(ws))
                }
            }
            world.sections.append(SidebarSection(kind: kind, nodes: nodes))
        }
        if r.chance(0.12) { world.filter = "workspace" }
        if r.chance(0.3) {
            world.hidden = [hiddenRef]
            world.hidesANode = world.sections.contains { $0.nodes.contains { if case let .item(item) = $0 { item.ref == hiddenRef } else { false } } }
        }
        if r.chance(0.3) { world.collapsed = [r.pick(world.sections).id] }
        if !loose.isEmpty, r.chance(0.12) {
            // Listed twice: the same workspace again, as the last row of the last section.
            world.sections[world.sections.count - 1].nodes.append(.workspace(r.pick(loose)))
            world.repeats = true
        }
        if !loose.isEmpty, r.chance(0.5) { world.active = r.pick(loose).id }
        return world
    }

    static func model(_ world: World) -> SidebarModel {
        let model = SidebarModel(sections: [])
        model.filterText = world.filter
        model.hiddenItemRefs = world.hidden
        model.collapsedSections = world.collapsed
        // Before the rows: a selection made after them opens its collapsed section by a set of its own.
        if let active = world.active { model.activeWorkspaceID = active }
        model.setSections(world.sections)
        return model
    }

    /// One random change of `rows` (the caller's rows, as it gives them to `setSections`): a loose row out, or a new
    /// one in, at its place in those rows, and the rows after it. Nil when there is no section.
    static func change(_ rows: [SidebarSection], serial: inout Int, _ r: inout Random) -> (change: SidebarLooseRowChange, next: [SidebarSection])? {
        guard !rows.isEmpty else { return nil }
        var loose: [(section: Int, node: Int, id: WorkspaceID)] = []
        for (s, section) in rows.enumerated() {
            for (n, node) in section.nodes.enumerated() {
                if case let .workspace(ws) = node { loose.append((s, n, ws.id)) }
            }
        }
        var next = rows
        if !loose.isEmpty, r.chance(0.5) {
            let gone = r.pick(loose)
            next[gone.section].nodes.remove(at: gone.node)
            return (.removed(gone.id, section: rows[gone.section].id, node: gone.node), next)
        }
        let s = Int(r.int(0 ... UInt64(rows.count - 1)))
        let n = Int(r.int(0 ... UInt64(rows[s].nodes.count)))
        serial += 1
        var ws = SidebarWorkspace(id: WorkspaceID("rc-\(serial)"), title: "workspace \(serial)")
        if r.chance(0.3) { ws.rowState = .creating }
        next[s].nodes.insert(.workspace(ws), at: n)
        return (.added(ws, section: rows[s].id, node: n), next)
    }

    /// Where the full set's model `full` and the entry's model `entry` differ, for the rows `rows` both show.
    static func faults(_ full: SidebarModel, _ entry: SidebarModel, rows: [SidebarSection]) -> [String] {
        var faults: [String] = []
        if full.sections != entry.sections { faults.append("sections") }
        if full.sectionsRevision != entry.sectionsRevision { faults.append("sectionsRevision \(full.sectionsRevision) / \(entry.sectionsRevision)") }
        if full.structureRevision != entry.structureRevision { faults.append("structureRevision \(full.structureRevision) / \(entry.structureRevision)") }
        if full.contentRevision != entry.contentRevision { faults.append("contentRevision \(full.contentRevision) / \(entry.contentRevision)") }
        switch (full.rowInsertion, entry.rowInsertion) {
        case (nil, nil): break
        case let (a?, b?):
            if a.from != b.from || a.to != b.to || a.content != b.content || a.section != b.section || a.node != b.node { faults.append("rowInsertion's fields") }
        default: faults.append("rowInsertion: full set \(full.rowInsertion == nil ? "none" : "one"), entry \(entry.rowInsertion == nil ? "none" : "one")")
        }
        switch (full.rowRemoval, entry.rowRemoval) {
        case (nil, nil): break
        case let (a?, b?):
            if a.from != b.from || a.to != b.to || a.content != b.content || a.section != b.section || a.node != b.node
                || a.workspace != b.workspace || (a.insertion == nil) != (b.insertion == nil) { faults.append("rowRemoval's fields") }
        default: faults.append("rowRemoval: full set \(full.rowRemoval == nil ? "none" : "one"), entry \(entry.rowRemoval == nil ? "none" : "one")")
        }
        for section in rows {
            for node in section.nodes {
                if case let .group(group) = node, full.group(group.id) != entry.group(group.id) || full.groupSection(group.id) != entry.groupSection(group.id) {
                    faults.append("group \(group.id)")
                }
                for ws in node.workspaces where full.listedPaths(of: ws.id) != entry.listedPaths(of: ws.id) { faults.append("row places of \(ws.id)") }
            }
        }
        if full.activeWorkspaceID != entry.activeWorkspaceID || full.selection != entry.selection { faults.append("selection") }
        if full.collapsedSections != entry.collapsedSections { faults.append("collapsedSections") }
        return faults
    }

    @Test func theOneRowEntryShowsWhatTheFullSetShows() {
        var steps = 0, taken = 0, plainSteps = 0, plainTaken = 0
        var broken: [String] = []
        for seed in 0 ..< Self.seeds {
            var r = Random(seed: 0x51DE_BA20_2611_1000 &+ UInt64(seed))
            var world = Self.world(&r)
            let (full, entry) = (Self.model(world), Self.model(world))
            var rows = world.sections
            for step in 0 ..< Self.stepsPerSeed {
                guard let (change, next) = Self.change(rows, serial: &world.serial, &r) else { break }
                full.setSections(next)
                let before = (rows: entry.sections, revision: entry.sectionsRevision, content: entry.contentRevision)
                let took = entry.apply(change)
                if !took {
                    if entry.sections != before.rows || entry.sectionsRevision != before.revision || entry.contentRevision != before.content {
                        broken.append("seed \(seed) step \(step): a refused entry changed the model")
                    }
                    entry.setSections(next)
                }
                rows = next
                steps += 1
                taken += took ? 1 : 0
                if world.plain {
                    plainSteps += 1
                    plainTaken += took ? 1 : 0
                }
                let faults = Self.faults(full, entry, rows: rows)
                if !faults.isEmpty { broken.append("seed \(seed) step \(step), \(took ? "entry" : "full set after a refusal"), \(change): \(faults)") }
            }
        }
        print("SIDEBAR-ROW-CHANGE-ENTRY equality seeds=\(Self.seeds) steps=\(steps) taken=\(taken) refused=\(steps - taken) plain_steps=\(plainSteps) plain_taken=\(plainTaken) faults=\(broken.count)")
        #expect(broken.isEmpty, "the entry and the full set differ in \(broken.count) steps; the first: \(broken.prefix(5))")
        #expect(plainSteps >= Self.seeds, "too few plain steps to prove the entry: \(plainSteps) of \(steps)")
        // The stated share: every plain step. A refusal there is a rule that names more than its doubt.
        #expect(plainTaken == plainSteps, "the entry took \(plainTaken) of the \(plainSteps) plain steps (no filter, each workspace listed once, no hidden node)")
    }

    /// One local section: 4 loose rows, a group of 2, a loose row.
    static func plainRows() -> [SidebarSection] {
        let loose = (0 ..< 4).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("rp-\($0)"), title: "workspace \($0)")) }
        let group = SidebarGroup(id: GroupID("rp-g"), name: "group", workspaces: [
            SidebarWorkspace(id: WorkspaceID("rp-m0"), title: "member 0"), SidebarWorkspace(id: WorkspaceID("rp-m1"), title: "member 1"),
        ])
        let nodes = loose + [.group(group), .workspace(SidebarWorkspace(id: WorkspaceID("rp-5"), title: "workspace 5"))]
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)]
    }

    @Test func aPlainCloseAndAPlainCreateTakeTheEntry() {
        let model = SidebarModel(sections: [])
        model.setSections(Self.plainRows())
        let from = model.sectionsRevision
        #expect(model.takesRowChanges)
        #expect(model.apply(.removed(WorkspaceID("rp-1"), section: .machine(.local), node: 1)), "a loose row listed once, no filter: the entry refused")
        #expect(model.sectionsRevision == from &+ 1 && model.structureRevision == model.sectionsRevision)
        #expect(model.rowRemoval?.workspace.id == WorkspaceID("rp-1") && model.rowRemoval?.to == model.sectionsRevision)
        #expect(!model.lists(WorkspaceID("rp-1")))
        // The group moved up one node: its lookup follows.
        #expect(model.group(GroupID("rp-g"))?.workspaces.count == 2)
        let new = SidebarWorkspace(id: WorkspaceID("rp-new"), title: "new", rowState: .creating)
        #expect(model.apply(.added(new, section: .machine(.local), node: 0)), "a new loose row, no filter: the entry refused")
        #expect(model.rowInsertion?.workspace?.id == new.id && model.rowInsertion?.to == model.sectionsRevision && model.rowRemoval == nil)
        #expect(model.group(GroupID("rp-g"))?.workspaces.count == 2)
        var expected = Self.plainRows()
        expected[0].nodes.remove(at: 1)
        expected[0].nodes.insert(.workspace(new), at: 0)
        #expect(model.sections == expected)
    }

    @Test func theEntryRefusesWhatItCanNotProve() {
        let section = SectionID.machine(.local)
        func refuses(_ change: SidebarLooseRowChange, _ why: Comment, rows: [SidebarSection]? = nil, _ prepare: (SidebarModel) -> Void = { _ in }) {
            let model = SidebarModel(sections: [])
            model.setSections(rows ?? Self.plainRows())
            prepare(model)
            let before = (model.sections, model.sectionsRevision)
            #expect(!model.apply(change), why)
            #expect(model.sections == before.0 && model.sectionsRevision == before.1, "a refused entry changed the model")
        }
        let gone = SidebarLooseRowChange.removed(WorkspaceID("rp-1"), section: section, node: 1)
        refuses(gone, "a filter text decides which rows show") { $0.filterText = "work" }
        refuses(.removed(WorkspaceID("rp-m0"), section: section, node: 4), "a group's member is not a loose row")
        refuses(.removed(WorkspaceID("rp-1"), section: section, node: 2), "the row is not at the named node")
        refuses(.removed(WorkspaceID("rp-1"), section: .custom("rp-none"), node: 1), "the list has no such section")
        refuses(.added(SidebarWorkspace(id: WorkspaceID("rp-2"), title: "again"), section: section, node: 0), "the list has the workspace already")
        refuses(.added(SidebarWorkspace(id: WorkspaceID("rp-new"), title: "new"), section: section, node: 9), "the node is past the section's end")
        var twice = Self.plainRows()
        twice[0].nodes.append(.workspace(SidebarWorkspace(id: WorkspaceID("rp-0"), title: "workspace 0")))
        refuses(gone, "a workspace listed twice: the list draws one row for it", rows: twice)
        var hidden = Self.plainRows()
        hidden[0].nodes.insert(.item(SidebarListItem(id: "rp-item", ref: Self.hiddenRef, title: "item")), at: 0)
        refuses(.removed(WorkspaceID("rp-1"), section: section, node: 2), "a hidden item: the model's nodes are not at the caller's places", rows: hidden) { model in
            model.hiddenItemRefs = [Self.hiddenRef]
            model.setSections(hidden)
        }
        refuses(gone, "the hidden items changed since the last set") { $0.hiddenItemRefs = [Self.hiddenRef] }
    }

    typealias Doc = SidebarDocArrangeIdempotenceTests

    /// A model whose list the sidebar document `projection` arranges, and the document's store.
    static func arranged(_ projection: SidebarDocProjection, _ rows: [SidebarSection]) -> (model: SidebarModel, store: SidebarDocStore) {
        let store = SidebarDocStore(remote: nil)
        store.shown = projection
        let model = SidebarModel(sections: [])
        model.docDrag = SidebarDocDrag(document: store, item: { Doc.drag.item($0) }, section: { id in id == .machine(.local) ? Doc.machine : nil },
                                       begin: { _ in [:] }, drop: { _, _ in })
        model.setSections(rows)
        return (model, store)
    }

    /// The document arrangement (`SidebarDocProjection.arrange`) places a machine list's rows by the document's order
    /// when that order has a link row: the entry does not know where it puts a row then, so it refuses, and the full
    /// set shows the change.
    @Test func aDocumentThatOrdersTheMachineListRefusesTheEntry() {
        let (full, entry) = (Self.arranged(Doc.projection(), Doc.raw()).model, Self.arranged(Doc.projection(), Doc.raw()).model)
        var next = Doc.raw()
        guard case let .workspace(first) = next[0].nodes[0] else {
            Issue.record("the fixture's first node is no loose row")
            return
        }
        next[0].nodes.remove(at: 0)
        #expect(!entry.takesRowChanges)
        #expect(!entry.apply(.removed(first.id, section: .machine(.local), node: 0)), "the entry took a change in a list the document orders")
        full.setSections(next)
        entry.setSections(next)
        #expect(Self.faults(full, entry, rows: next).isEmpty)
    }

    /// A document that keeps the machine list's order (no link row in it), as the real app's document does for a list
    /// of workspaces and groups: Pinned band group `itm_gp` (member `ws-0`) above This Mac; This Mac: `ws-1`, `ws-4`,
    /// group `itm_gm` (member `ws-2`), `ws-5`; a section after the lists with group `itm_ga` (member `ws-3`).
    static func keptOrderProjection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            Doc.pinned: SidebarDocSection(id: Doc.pinned, kind: .pinned, region: .top),
            Doc.machine: SidebarDocSection(id: Doc.machine, kind: .machine(session: Doc.session)),
            Doc.after: SidebarDocSection(id: Doc.after, kind: .custom, title: "Later"),
        ], items: [
            "itm_gp": SidebarDocItem(id: "itm_gp", section: Doc.pinned, body: .group(name: "Pinned one", color: nil, icon: nil, collapsed: false)),
            "itm_0": SidebarDocItem(id: "itm_0", section: Doc.pinned, parent: "itm_gp", body: .workspace(Doc.ref("ws-0"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: Doc.machine, body: .workspace(Doc.ref("ws-1"))),
            "itm_4": SidebarDocItem(id: "itm_4", section: Doc.machine, body: .workspace(Doc.ref("ws-4"))),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: Doc.machine, body: .group(name: "Loose one", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: Doc.machine, parent: "itm_gm", body: .workspace(Doc.ref("ws-2"))),
            "itm_5": SidebarDocItem(id: "itm_5", section: Doc.machine, body: .workspace(Doc.ref("ws-5"))),
            "itm_ga": SidebarDocItem(id: "itm_ga", section: Doc.after, body: .group(name: "Later one", color: nil, icon: nil, collapsed: false)),
            "itm_3": SidebarDocItem(id: "itm_3", section: Doc.after, parent: "itm_ga", body: .workspace(Doc.ref("ws-3"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gp", kind: "group", section: Doc.pinned, item: "itm_gp"),
            SidebarDocRow(key: "itm_0", kind: "item", section: Doc.pinned, parent: "itm_gp", depth: 1, item: "itm_0", ref: Doc.ref("ws-0")),
            SidebarDocRow(key: "itm_1", kind: "item", section: Doc.machine, item: "itm_1", ref: Doc.ref("ws-1")),
            SidebarDocRow(key: "itm_4", kind: "item", section: Doc.machine, item: "itm_4", ref: Doc.ref("ws-4")),
            SidebarDocRow(key: "itm_gm", kind: "group", section: Doc.machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_2", kind: "item", section: Doc.machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: Doc.ref("ws-2")),
            SidebarDocRow(key: "itm_5", kind: "item", section: Doc.machine, item: "itm_5", ref: Doc.ref("ws-5")),
            SidebarDocRow(key: "itm_ga", kind: "group", section: Doc.after, item: "itm_ga"),
            SidebarDocRow(key: "itm_3", kind: "item", section: Doc.after, parent: "itm_ga", depth: 1, item: "itm_3", ref: Doc.ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    /// The bridge's mapping for `keptOrderProjection`: each group in This Mac's section, the band groups between its rows.
    static func keptOrderRows() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(Doc.ws("ws-1")), Doc.group("itm_gp", "ws-0"), .workspace(Doc.ws("ws-4")), Doc.group("itm_gm", "ws-2"),
            Doc.group("itm_ga", "ws-3"), .workspace(Doc.ws("ws-5")),
        ])]
    }

    /// The real app's case (SIDEBAR ROW CHANGE 2, part C, the model half): a sidebar document arranges the list. It
    /// takes the band groups out of the machine list, so the caller's node is not the model's node. The entry takes
    /// the change at the mapped node, marks a new row as the document does, and refuses after the document changed.
    @Test func theEntryTakesALooseRowUnderADocumentThatKeepsTheListOrder() {
        var rows = Self.keptOrderRows()
        let full = Self.arranged(Self.keptOrderProjection(), rows).model
        let (entry, store) = Self.arranged(Self.keptOrderProjection(), rows)
        let machine = SectionID.machine(.local)
        #expect(entry.sections.first(where: { $0.id == machine })?.nodes.count == 4, "the document did not take the 2 band groups out of the machine list")
        #expect(entry.takesRowChanges, "a document that keeps the list order: the entry takes no change")
        func node(_ id: String) -> Int { rows[0].nodes.firstIndex { $0.id == .workspace(WorkspaceID(id)) } ?? -1 }
        func step(_ change: SidebarLooseRowChange, _ next: [SidebarSection], takes: Bool = true, _ why: String) {
            full.setSections(next)
            let took = entry.apply(change)
            #expect(took == takes, "\(why): took=\(took)")
            if !took { entry.setSections(next) }
            rows = next
            let faults = Self.faults(full, entry, rows: rows)
            #expect(faults.isEmpty, "\(why): the entry and the full set differ: \(faults)")
        }
        var next = rows
        next[0].nodes.remove(at: node("ws-4"))
        step(.removed(WorkspaceID("ws-4"), section: machine, node: node("ws-4")), next, "a loose row after a band group goes out")
        var new = SidebarWorkspace(id: WorkspaceID("ws-9"), title: "new", rowState: .creating)
        new.isArchived = true // the document does not archive it: the arrangement clears the mark
        next = rows
        next[0].nodes.insert(.workspace(new), at: 1)
        step(.added(new, section: machine, node: 1), next, "a new row right before a band group")
        let last = SidebarWorkspace(id: WorkspaceID("ws-8"), title: "last")
        next = rows
        next[0].nodes.append(.workspace(last))
        step(.added(last, section: machine, node: rows[0].nodes.count), next, "a new row at the end, after 2 band groups")
        next = rows
        next[0].nodes.remove(at: node("ws-5"))
        step(.removed(WorkspaceID("ws-5"), section: machine, node: node("ws-5")), next, "a loose row after 2 band groups goes out")
        next = rows
        next[0].nodes.remove(at: 0)
        step(.removed(WorkspaceID("ws-1"), section: machine, node: 0), next, "the first row goes out")
        // A band group's member is no loose row of the machine list, and the group's node is not in the model's list.
        let pinned = rows[0].nodes.firstIndex { $0.id == .group(GroupID("itm_gp")) } ?? -1
        let before = (entry.sections, entry.sectionsRevision)
        #expect(!entry.apply(.removed(WorkspaceID("ws-0"), section: machine, node: pinned)), "the entry took a band group's node")
        #expect(entry.sections == before.0 && entry.sectionsRevision == before.1, "a refused entry changed the model")
        // The document changed since the last full set: the entry can not know what it arranges now.
        store.shown = Self.keptOrderProjection()
        #expect(!entry.takesRowChanges, "the document changed: the entry still takes changes")
        next = rows
        next[0].nodes.remove(at: node("ws-8"))
        step(.removed(WorkspaceID("ws-8"), section: machine, node: node("ws-8")), next, takes: false, "the document changed since the last full set")
        // The full set after the refusal arranged by the document as it is now.
        #expect(entry.takesRowChanges, "a full set by the document as it is now: the entry takes no change")
    }

    /// The property of `theOneRowEntryShowsWhatTheFullSetShows` under the document of `keptOrderProjection`: random
    /// loose rows go out and come in at each place between the band groups; some steps come after a document change.
    @Test func theOneRowEntryShowsWhatTheFullSetShowsUnderADocument() {
        let seeds = 200
        var steps = 0, taken = 0, documentChanges = 0
        var broken: [String] = []
        for seed in 0 ..< seeds {
            var r = Random(seed: 0x51DE_BA20_2611_2000 &+ UInt64(seed))
            var rows = Self.keptOrderRows()
            let full = Self.arranged(Self.keptOrderProjection(), rows).model
            let (entry, store) = Self.arranged(Self.keptOrderProjection(), rows)
            var serial = 100 // "rc-101" and later: no item of the document
            for step in 0 ..< 6 {
                guard let (change, next) = Self.change(rows, serial: &serial, &r) else { break }
                let changed = r.chance(0.2)
                if changed { store.shown = Self.keptOrderProjection() }
                full.setSections(next)
                let took = entry.apply(change)
                if !took { entry.setSections(next) }
                rows = next
                steps += 1
                if changed {
                    documentChanges += 1
                    if took { broken.append("seed \(seed) step \(step): the entry took \(change) after the document changed") }
                } else {
                    taken += took ? 1 : 0
                    if !took { broken.append("seed \(seed) step \(step): the entry refused \(change)") }
                }
                let faults = Self.faults(full, entry, rows: rows)
                if !faults.isEmpty { broken.append("seed \(seed) step \(step), \(took ? "entry" : "full set after a refusal"), \(change): \(faults)") }
            }
        }
        print("SIDEBAR-ROW-CHANGE-ENTRY document seeds=\(seeds) steps=\(steps) taken=\(taken) document_changes=\(documentChanges) faults=\(broken.count)")
        #expect(broken.isEmpty, "under a document the entry and the full set differ, or the entry refused, in \(broken.count) steps; the first: \(broken.prefix(5))")
        #expect(taken == steps - documentChanges && taken >= seeds * 3, "the entry took \(taken) of the \(steps - documentChanges) steps with an unchanged document")
    }
}
