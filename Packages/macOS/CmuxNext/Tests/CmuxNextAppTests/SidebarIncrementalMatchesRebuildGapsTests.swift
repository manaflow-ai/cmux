import AppKit
@testable import CmuxNextDesign
import Foundation
import QuartzCore
@testable import CmuxNextSidebar
import Testing

/// The cases `SidebarIncrementalMatchesRebuildTests` (#23389) left out: Group by Folder, a filter, Pinned and custom
/// sections, a drag of several selected rows, and every one of its operations with motion on. The rule is the same:
/// once an operation settles, the list on screen equals a list built fresh from the same model. Each operation goes
/// through the list's own pointer and key handlers (`mouseDown`, `mouseDragged`, `mouseUp`, `keyDown`), as a person
/// does it, and the document's echo then shows it as the app's model change does.
@MainActor @Suite(.serialized) struct SidebarIncrementalMatchesRebuildGapsTests {
    typealias Base = SidebarIncrementalMatchesRebuildTests
    static let machineSection = "sec_m_s1", top = "sec_top", pinned = "sec_pinned", projects = "sec_proj"
    static let work = Base.work, infra = Base.infra, folded = Base.folded, pin = GroupID("g-pin"), proj = GroupID("g-proj")

    enum Scenario: String, CaseIterable, CustomTestStringConvertible {
        case groupByFolderRefusesARowDrag, groupByFolderTabIntoGroup, groupByFolderFolderChanges
        case filteredMemberIntoAnotherGroup, filteredLooseIntoGroupThenEscape
        case groupIntoCustomSection, workspaceIntoPinnedGroup, pinnedMemberOutToMachine
        case twoRowsInGroupDown, twoLooseRowsIntoGroup, rowsFromTwoGroupsToTop
        var testDescription: String { rawValue }

        var groupsByFolder: Bool { rawValue.hasPrefix("groupByFolder") }
        /// Pinned (a group in `sec_pinned`) and a custom section (a group in `sec_proj`) above the machine list,
        /// under the top block (Home and the App Store), as the document arranges them.
        var hasDocSections: Bool { [Scenario.groupIntoCustomSection, .workspaceIntoPinnedGroup, .pinnedMemberOutToMachine].contains(self) }
    }

    /// The home daemon's document as the test's echo applies it: every section's top-level nodes, a group with its members.
    final class Doc {
        enum Node { case workspace(String), group(GroupID, [String]) }
        struct Section {
            let id: String
            let kind: SidebarSection.Kind
            var nodes: [Node]
        }

        var sections: [Section]
        /// Each workspace's folder (Group by Folder buckets loose rows by it).
        var folders: [String: String] = [:]
        var drops: [SidebarDocTarget] = []

        init(docSections: Bool) {
            let machine = Section(id: machineSection, kind: .machine(Base.machine), nodes: [
                .workspace("scratch"), .workspace("loose2"), .group(work, ["docs", "web", "api"]), .group(infra, ["deploy"]),
                .group(folded, ["f1", "f2"]),
            ])
            guard docSections else {
                sections = [machine]
                return
            }
            sections = [
                Section(id: top, kind: .custom(SidebarCustomSection(id: top)), nodes: []),
                Section(id: pinned, kind: .custom(SidebarCustomSection(id: pinned)), nodes: [.group(pin, ["p1"])]),
                Section(id: projects, kind: .custom(SidebarCustomSection(id: projects, title: "Projects")), nodes: [.group(proj, ["q1", "q2"])]),
                machine,
            ]
        }

        static func item(_ node: Node) -> String {
            switch node {
            case let .workspace(id): "w_\(id)"
            case let .group(id, _): "g_\(id.rawValue)"
            }
        }

        /// Moves `items` (`w_<workspace>`, `g_<group>`) to `target`, as the reducer's `move` does; an item the
        /// document does not hold yet (a tab dropped as a new workspace) is added there.
        func move(_ items: [String], to target: SidebarDocTarget) {
            drops.append(target)
            var moved: [Node] = []
            for item in items {
                if item.hasPrefix("g_") {
                    for s in sections.indices {
                        if let index = sections[s].nodes.firstIndex(where: { Self.item($0) == item }) { moved.append(sections[s].nodes.remove(at: index)) }
                    }
                    continue
                }
                let id = String(item.dropFirst(2))
                for s in sections.indices {
                    sections[s].nodes.removeAll { if case let .workspace(w) = $0 { w == id } else { false } }
                    sections[s].nodes = sections[s].nodes.map { if case let .group(g, members) = $0 { .group(g, members.filter { $0 != id }) } else { $0 } }
                }
                moved.append(.workspace(id))
            }
            guard let s = sections.firstIndex(where: { $0.id == target.section }) else { return }
            if let parent = target.parent, let at = sections[s].nodes.firstIndex(where: { Self.item($0) == parent }),
               case .group(let group, var members) = sections[s].nodes[at] {
                let ids = moved.compactMap { if case let .workspace(id) = $0 { id } else { nil } }
                members.insert(contentsOf: ids, at: Base.Doc.index(in: members.map { "w_\($0)" }, target))
                sections[s].nodes[at] = .group(group, members)
                return
            }
            sections[s].nodes.insert(contentsOf: moved, at: Base.Doc.index(in: sections[s].nodes.map(Self.item), target))
        }

        /// Where `id` is now: its section and group.
        func place(of id: String) -> (section: String, group: GroupID?)? {
            for section in sections {
                for node in section.nodes {
                    switch node {
                    case let .workspace(w) where w == id: return (section.id, nil)
                    case let .group(g, members) where members.contains(id): return (section.id, g)
                    default: continue
                    }
                }
            }
            return nil
        }

        /// The members of group `id`, in order.
        func members(_ id: GroupID) -> [String] {
            for section in sections {
                for case let .group(g, members) in section.nodes where g == id { return members }
            }
            return []
        }

        func workspace(_ id: String) -> SidebarWorkspace {
            var workspace = Base.ws(id)
            workspace.folder = folders[id]
            return workspace
        }

        /// The sections the daemon's echo shows; a group keeps the fold the window shows (Folded starts folded).
        func shown(_ model: SidebarModel) -> [SidebarSection] {
            let colors: [GroupID: GroupColor] = [work: .blue, infra: .green, folded: .purple, pin: .orange, proj: .red]
            return sections.map { section in
                SidebarSection(kind: section.kind, nodes: section.nodes.map { node -> SidebarNode in
                    switch node {
                    case let .workspace(id): return .workspace(workspace(id))
                    case let .group(id, members):
                        return .group(SidebarGroup(id: id, name: id.rawValue, color: colors[id] ?? .blue, isCollapsed: model.group(id)?.isCollapsed ?? false,
                                                   workspaces: members.map(workspace)))
                    }
                })
            }
        }
    }

    // MARK: The list under test

    /// The sidebar on the document's sections, with the document's drag the app wires; `groupsByFolder` turns on
    /// `sidebar.groupBy` "folder" in its settings, as the Projects menu does.
    static func fixture(_ doc: Doc, groupsByFolder: Bool = false) -> (SidebarView, NSWindow) {
        let model = SidebarModel(sections: [], activeWorkspaceID: WorkspaceID("scratch"))
        model.sections = doc.shown(model)
        model.setGroupCollapsed(folded, true)
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { id in id == .machine(.local) ? machineSection : nil }, begin: { [doc] items in
            // A dragged group goes before or after a group, never into one or among its members. A loose workspace in
            // Pinned or a custom section is a tile, not a list row: a workspace drag goes only into their groups.
            let group = items.contains { $0.hasPrefix("g_") }, workspace = items.contains { $0.hasPrefix("w_") }
            var table: [String: SidebarDocAcceptance] = [:]
            for section in doc.sections {
                let machine = section.kind == .machine(Base.machine)
                table[section.id] = SidebarDocAcceptance(before: false, into: machine, after: false)
                for node in section.nodes {
                    switch node {
                    case let .workspace(id): table["w_\(id)"] = SidebarDocAcceptance(before: true, into: false, after: true)
                    case let .group(id, members):
                        let beside = machine || !workspace
                        table["g_\(id.rawValue)"] = SidebarDocAcceptance(before: beside, into: !group, after: beside)
                        for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: !group, into: false, after: !group) }
                    }
                }
            }
            return table
        }, drop: { [doc] items, target in doc.move(items, to: target) })
        let design = DesignSettings()
        if groupsByFolder { design.sidebarSections.groupBy = .folder }
        return Base.sidebar(model, design: design)
    }

    /// The echo of a drop: the card lands, then the document's new order shows as the app's model change does.
    static func echo(_ sidebar: SidebarView, _ doc: Doc) {
        let list = sidebar.list
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        list.model.sections = doc.shown(list.model)
        sidebar.renderNow()
    }

    // MARK: Pointer and keys

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in list: SidebarListView, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try #require(list.window)
        return try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    static func center(_ list: SidebarListView, _ key: SidebarRowKey) throws -> NSPoint {
        let row = try Base.row(list, key)
        return NSPoint(x: 80, y: row.y + row.height / 2)
    }

    /// A click on `key`'s row with `flags` held (Cmd adds the row to the selection).
    static func click(_ list: SidebarListView, _ key: SidebarRowKey, _ flags: NSEvent.ModifierFlags = []) throws {
        let point = try center(list, key)
        list.mouseDown(with: try mouse(.leftMouseDown, at: point, in: list, flags: flags))
        list.mouseUp(with: try mouse(.leftMouseUp, at: point, in: list, flags: flags))
    }

    enum Edge { case top, bottom }

    /// Presses `key`'s row and drags it: a first move lifts it, then the card's `edge` goes in 4 pt steps to the y
    /// `to` reads off the list as it shows the lifted drag (the source slot closed); then the button comes up.
    /// False when the press lifted nothing (the list refused the drag).
    @discardableResult
    static func drag(_ list: SidebarListView, _ key: SidebarRowKey, _ edge: Edge, to: (SidebarListView) throws -> CGFloat) throws -> Bool {
        let start = try center(list, key)
        list.mouseDown(with: try mouse(.leftMouseDown, at: start, in: list))
        let lifted = NSPoint(x: start.x, y: start.y + 6)
        list.mouseDragged(with: try mouse(.leftMouseDragged, at: lifted, in: list))
        guard let card = list.drag?.lift.frame else {
            list.mouseUp(with: try mouse(.leftMouseUp, at: lifted, in: list))
            return false
        }
        let dy = try to(list) - (edge == .top ? card.minY : card.maxY)
        // A hand's path: the drop moves one slot at a time as an edge passes a row's middle.
        let steps = max(1, Int((abs(dy) / 4).rounded(.up)))
        for step in 1...steps {
            list.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: lifted.x, y: lifted.y + dy * CGFloat(step) / CGFloat(steps)), in: list))
        }
        list.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: lifted.x, y: lifted.y + dy), in: list))
        return true
    }

    /// The row of `key` as the list shows it now.
    static func shown(_ list: SidebarListView, _ key: SidebarRowKey) throws -> SidebarRow { try Base.row(list, key) }

    /// The middle of `key`'s row as the list shows it now.
    static func mid(_ list: SidebarListView, _ key: SidebarRowKey) throws -> CGFloat {
        let row = try Base.row(list, key)
        return row.y + row.height / 2
    }

    static func ws(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    // MARK: Scenarios

    static func run(_ scenario: Scenario, _ sidebar: SidebarView, _ doc: Doc) async throws {
        let list = sidebar.list, model = list.model
        switch scenario {
        case .groupByFolderRefusesARowDrag:
            // The drawn order is not the model's: a row drag does not lift, and the list stays as it was.
            let lifted = try drag(list, ws("loose2"), .bottom) { try mid($0, ws("docs")) }
            #expect(!lifted, "a row lifted while the list is grouped by folder")
            #expect(doc.drops.isEmpty, "a drop went through while the list is grouped by folder")
        case .groupByFolderTabIntoGroup:
            // A tab from a pane still drops: over the folded group (it springs open), then into Work between docs and web.
            list.springLoadDelay = .zero
            let foldedY = try mid(list, .group(folded))
            _ = list.externalDragMoved(windowPoint: list.convert(NSPoint(x: 80, y: foldedY), to: nil), sourceMachine: nil)
            try? await Task.sleep(for: .milliseconds(50))
            await Base.expectMatchesRebuild(sidebar, "after the folded group springs open")
            let web = try shown(list, ws("web"))
            _ = list.externalDragMoved(windowPoint: list.convert(NSPoint(x: 80, y: web.y), to: nil), sourceMachine: nil)
            let drop = list.externalDragEnded()
            #expect(drop == .newWorkspace(section: .machine(.local), group: work, index: 1), "the tab drag proposed \(String(describing: drop))")
            guard case let .newWorkspace(_, group?, index) = drop else { return }
            doc.move(["w_moved"], to: SidebarDocTarget(section: machineSection, parent: "g_\(group.rawValue)", index: index))
        case .groupByFolderFolderChanges:
            // A loose row's shell changes directory: it moves to another folder's bucket, which no patch can show.
            var row = try #require(model.workspace(WorkspaceID("loose2")))
            row.folder = "~/b"
            #expect(!model.patchWorkspaces([row]), "a folder change patched the row in place under Group by Folder")
            doc.folders["loose2"] = "~/b"
        case .filteredMemberIntoAnotherGroup:
            // "o" leaves loose2, docs and deploy; deploy goes up into Work, before docs.
            try drag(list, ws("deploy"), .top) { try shown($0, ws("docs")).y + 2 }
            #expect(doc.place(of: "deploy")?.group == work, "deploy did not go into Work: \(doc.drops)")
        case .filteredLooseIntoGroupThenEscape:
            try drag(list, ws("loose2"), .bottom) { try mid($0, ws("deploy")) + 2 }
            #expect(doc.place(of: "loose2")?.group == infra, "loose2 did not go into Infra: \(doc.drops)")
            echo(sidebar, doc)
            await Base.expectMatchesRebuild(sidebar, "after the filtered drop")
            // Escape clears the filter.
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: list.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            list.keyDown(with: escape)
            #expect(model.filterText.isEmpty, "Escape left the filter")
            sidebar.renderNow()
            return
        case .groupIntoCustomSection:
            // Work's header up past the custom section's group: its top past scratch's middle, not past Projects' middle.
            try drag(list, .group(work), .top) { try shown($0, ws("scratch")).y + 1 }
            #expect(doc.drops.last?.section == projects, "Work did not go into the custom section: \(doc.drops)")
        case .workspaceIntoPinnedGroup:
            try drag(list, ws("api"), .top) { try shown($0, ws("p1")).y + 2 }
            #expect(doc.place(of: "api").map { $0.section == pinned && $0.group == pin } == true, "api did not go into Pinned's group: \(doc.drops)")
        case .pinnedMemberOutToMachine:
            try drag(list, ws("p1"), .bottom) { try mid($0, ws("scratch")) + 2 }
            #expect(doc.place(of: "p1").map { $0.section != pinned } == true, "p1 did not leave Pinned: \(doc.drops)")
        case .twoRowsInGroupDown:
            try click(list, ws("docs"))
            try click(list, ws("web"), .command)
            try drag(list, ws("docs"), .bottom) { try mid($0, ws("api")) + 2 }
            #expect(doc.members(work) == ["api", "docs", "web"], "docs and web did not go after api: \(doc.members(work))")
        case .twoLooseRowsIntoGroup:
            try click(list, ws("scratch"))
            try click(list, ws("loose2"), .command)
            try drag(list, ws("scratch"), .bottom) { try mid($0, ws("docs")) + 2 }
            // Both rows go into Work together, in their order.
            let members = doc.members(work)
            #expect(members.firstIndex(of: "scratch").map { members.dropFirst($0).starts(with: ["scratch", "loose2"]) } == true,
                    "the two rows did not land together in Work: \(members)")
        case .rowsFromTwoGroupsToTop:
            try click(list, ws("web"))
            try click(list, ws("deploy"), .command)
            try drag(list, ws("web"), .top) { try shown($0, ws("scratch")).y + 2 }
            #expect(doc.place(of: "web").map { $0.group == nil } == true && doc.place(of: "deploy").map { $0.group == nil } == true,
                    "web and deploy did not leave their groups: \(doc.drops)")
        }
        if !scenario.groupsByFolder || scenario == .groupByFolderTabIntoGroup { #expect(!doc.drops.isEmpty, "\(scenario.rawValue): nothing dropped") }
        echo(sidebar, doc)
    }

    @Test(arguments: Scenario.allCases)
    func theListMatchesAFreshRebuild(_ scenario: Scenario) async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true // as in the base suite: a rebuild draws ends, not flights
        defer { Motion.reduceMotionOverride = previousMotion }
        let doc = Doc(docSections: scenario.hasDocSections)
        if scenario.groupsByFolder { doc.folders = ["scratch": "~/a", "loose2": "~/a", "docs": "~/b"] }
        let f0 = CACurrentMediaTime()
        let (sidebar, window) = Self.fixture(doc, groupsByFolder: scenario.groupsByFolder)
        print(String(format: "MATCH-REBUILD-DIAG3 fixture %.1fms", (CACurrentMediaTime() - f0) * 1000))
        defer { window.close() }
        let model = sidebar.list.model
        if scenario.groupsByFolder {
            try #require(sidebar.list.displayed.rows.contains { if case .folder = $0.key { true } else { false } }, "the list draws no folder header")
        }
        if scenario.rawValue.hasPrefix("filtered") {
            model.filterText = "o"
            sidebar.renderNow()
            try #require(model.filterMatches == [WorkspaceID("loose2"), WorkspaceID("docs"), WorkspaceID("deploy")])
        }
        await Base.expectMatchesRebuild(sidebar, "at rest")
        let r0 = CACurrentMediaTime()
        try await Self.run(scenario, sidebar, doc)
        print(String(format: "MATCH-REBUILD-DIAG3 run %@ %.1fms", scenario.rawValue, (CACurrentMediaTime() - r0) * 1000))
        await Base.expectMatchesRebuild(sidebar, "after \(scenario.rawValue)")
        await Base.foldsAndClicks(sidebar, after: scenario.rawValue, groups: Base.allGroups + [Self.pin, Self.proj],
                                  clicking: ["web", "f1", "scratch", "p1", "q1"])
    }

    /// The base suite's operations with motion on: the drag's springs and the card's flight run, and the list still
    /// ends where a rebuild draws it.
    @Test(arguments: Base.Operation.allCases)
    func theListMatchesAFreshRebuildWithMotionOn(_ operation: Base.Operation) async throws {
        try await Base.check(operation, reduceMotion: false)
    }
}
