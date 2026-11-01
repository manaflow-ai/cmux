import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import QuartzCore
@testable import CmuxNextSidebar
import Testing

/// #23182 was one bug of a class: an incremental sidebar path (`SidebarGroupLineViews.showMissing`, a fold's
/// `foldLines`) drew something a full rebuild from the same model would not, and it stayed until a rebuild.
/// Rule: after every operation the user can do, once it settles, the list on screen equals a list built fresh from the
/// same model: its rows and their order and frames, group headers and rails, selection, folds and placeholders.
/// Each operation runs through the path the app uses (the sidebar document's drag, the model's fold, a click, an
/// external tab drag), then the daemon's echo shows it as the app's model change does.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarIncrementalMatchesRebuildTests {
    static let section = "sec_m_s1"
    static let work = GroupID("g-work"), infra = GroupID("g-infra"), empty = GroupID("g-empty"), folded = GroupID("g-folded")
    static let allGroups = [work, infra, empty, folded]
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    enum Operation: String, CaseIterable, CustomTestStringConvertible {
        case groupPastEmptyGroup, groupPastFoldedGroup, foldedGroupUp, reorderInGroup, looseIntoGroup, memberOutOfGroup, tabAcrossGroups
        var testDescription: String { rawValue }
    }

    /// The home daemon's document as the test's echo applies it: top-level nodes, a group with its members.
    final class Doc {
        enum Node { case workspace(String), group(GroupID, [String]) }
        var nodes: [Node] = [.workspace("scratch"), .workspace("loose2"), .group(work, ["docs", "web", "api"]), .group(infra, ["deploy"]),
                             .group(empty, []), .group(folded, ["f1", "f2"])]
        var drops: [SidebarDocTarget] = []

        static func id(_ item: String) -> String { String(item.dropFirst(2)) }

        /// Moves `items` (`w_<workspace>`, `g_<group>`) to `target`, as the reducer's `move` does.
        func move(_ items: [String], to target: SidebarDocTarget) {
            drops.append(target)
            var moved: [Node] = []
            for item in items {
                if item.hasPrefix("g_"), let index = nodes.firstIndex(where: { if case let .group(id, _) = $0 { "g_\(id.rawValue)" == item } else { false } }) {
                    moved.append(nodes.remove(at: index))
                } else if item.hasPrefix("w_") {
                    let id = Self.id(item)
                    nodes.removeAll { if case let .workspace(w) = $0 { w == id } else { false } }
                    nodes = nodes.map { if case let .group(g, members) = $0 { .group(g, members.filter { $0 != id }) } else { $0 } }
                    moved.append(.workspace(id))
                }
            }
            if let parent = target.parent, let at = nodes.firstIndex(where: { if case let .group(g, _) = $0 { "g_\(g.rawValue)" == parent } else { false } }),
               case .group(let group, var members) = nodes[at] {
                let ids = moved.compactMap { if case let .workspace(id) = $0 { id } else { nil } }
                members.insert(contentsOf: ids, at: Self.index(in: members.map { "w_\($0)" }, target))
                nodes[at] = .group(group, members)
                return
            }
            nodes.insert(contentsOf: moved, at: Self.index(in: nodes.map(Self.item), target))
        }

        static func item(_ node: Node) -> String {
            switch node {
            case let .workspace(id): "w_\(id)"
            case let .group(id, _): "g_\(id.rawValue)"
            }
        }

        static func index(in items: [String], _ target: SidebarDocTarget) -> Int {
            if let before = target.before, let at = items.firstIndex(of: before) { return at }
            if let after = target.after, let at = items.firstIndex(of: after) { return at + 1 }
            return min(target.index ?? items.count, items.count)
        }

        /// The sections the daemon's echo shows; a group keeps the fold the window shows.
        func sections(_ model: SidebarModel, adding added: (group: GroupID, id: String, index: Int?)? = nil) -> [SidebarSection] {
            let nodes = nodes.map { node -> SidebarNode in
                switch node {
                case let .workspace(id): return .workspace(SidebarIncrementalMatchesRebuildTests.ws(id))
                case let .group(id, members):
                    var all = members
                    if let added, added.group == id { all.insert(added.id, at: min(added.index ?? all.count, all.count)) }
                    let (name, color): (String, GroupColor) = switch id {
                    case work: ("Work", .blue)
                    case infra: ("Infra", .green)
                    case empty: ("Empty group", .red)
                    default: ("Folded", .purple)
                    }
                    return .group(SidebarGroup(id: id, name: name, color: color, isCollapsed: model.group(id)?.isCollapsed ?? false,
                                               workspaces: all.map(SidebarIncrementalMatchesRebuildTests.ws)))
                }
            }
            return [SidebarSection(kind: .machine(machine), nodes: nodes)]
        }
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    // MARK: The two lists

    /// A sidebar in a window of the list's size, drawn from `model`.
    static func sidebar(_ model: SidebarModel, design: DesignSettings = DesignSettings()) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: sidebar.frame)
        window.contentView?.addSubview(sidebar)
        sidebar.list.pointerIsOverList = { _ in false } // nothing waits for the pointer to leave
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        return (sidebar, window)
    }

    /// The sidebar under test, on the fixture's model, with the document's drag the app wires.
    static func fixture(_ doc: Doc) -> (SidebarView, NSWindow) {
        let model = SidebarModel(sections: [], activeWorkspaceID: WorkspaceID("scratch"))
        model.sections = doc.sections(model)
        model.setGroupCollapsed(folded, true)
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { [doc] items in
            // A dragged group goes before or after a group, never into one or among its members.
            let group = items.contains { $0.hasPrefix("g_") }
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            for node in doc.nodes {
                switch node {
                case let .workspace(id): table["w_\(id)"] = SidebarDocAcceptance(before: true, into: false, after: true)
                case let .group(id, members):
                    table["g_\(id.rawValue)"] = SidebarDocAcceptance(before: true, into: !group, after: true)
                    for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: !group, into: false, after: !group) }
                }
            }
            return table
        }, drop: { [doc] items, target in doc.move(items, to: target) })
        return sidebar(model)
    }

    /// A list built fresh from a copy of `model` and `design` (its own model, so `model`'s callbacks stay with the list under test).
    static func rebuilt(from model: SidebarModel, design: DesignSettings) -> (SidebarView, NSWindow) {
        let copy = SidebarModel(sections: model.sections, activeWorkspaceID: model.activeWorkspaceID)
        copy.selectedItem = model.selectedItem
        copy.selection = model.selection
        copy.revealedMembers = model.revealedMembers
        copy.filterText = model.filterText
        copy.collapsedSections = model.collapsedSections
        copy.collapsedLayoutSections = model.collapsedLayoutSections
        copy.layout = model.layout
        copy.itemInfo = model.itemInfo
        copy.docDrag = model.docDrag // the document's blocks draw only on the document
        let settings = DesignSettings()
        settings.sidebarSections = design.sidebarSections // Group by Folder
        return sidebar(copy, design: settings)
    }

    // MARK: Snapshot

    /// What a list draws, rounded to half a point: one line per row, row view, rail and state, for a readable diff.
    struct Snapshot: Equatable {
        var layout: [String]
        var rowViews: [String]
        var rails: [String]
        var railModel: [String]
        var state: [String]

        var fields: [(String, [String])] { [("layout", layout), ("row views", rowViews), ("rails", rails), ("rail lines", railModel), ("state", state)] }

        /// The lines that differ, field by field.
        func diff(_ fresh: Snapshot) -> String {
            zip(fields, fresh.fields).compactMap { mine, theirs -> String? in
                guard mine.1 != theirs.1 else { return nil }
                let only = mine.1.filter { !theirs.1.contains($0) }, missing = theirs.1.filter { !mine.1.contains($0) }
                let order = only.isEmpty && missing.isEmpty ? "\n      order: \(mine.1)\n      fresh: \(theirs.1)" : ""
                return "  \(mine.0):" + only.map { "\n    + \($0)" }.joined() + missing.map { "\n    - \($0)" }.joined() + order
            }.joined(separator: "\n")
        }
    }

    static func r(_ value: CGFloat) -> String { String(format: "%g", (value * 2).rounded() / 2) }
    static func r(_ rect: CGRect) -> String { "(\(r(rect.minX)),\(r(rect.minY)) \(r(rect.width))x\(r(rect.height)))" }

    static func name(_ key: SidebarRowKey) -> String {
        switch key {
        case let .section(id): "section \(id)"
        case let .group(id): "group \(id.rawValue)"
        case let .workspace(id): "ws \(id.rawValue)"
        case let .emptySection(id): "empty section \(id)"
        default: "\(key)"
        }
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview -> [T] in (subview as? T).map { [$0] } ?? views(type, in: subview) }
    }

    /// Shows on screen: not hidden, not see-through, inside the list.
    static func shows(_ view: NSView, in list: NSView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0.01 && view.convert(view.bounds, to: list).intersects(list.bounds)
    }

    static func snapshot(_ list: SidebarListView) -> Snapshot {
        let layout = list.displayed.rows.map { row in
            "\(name(row.key)) y \(r(row.y)) h \(r(row.height)) in \(row.group?.rawValue ?? "-") depth \(row.depth)"
                + "\(row.isCollapsed ? " folded" : "")\(row.isLastInGroup ? " last" : "") frame \(r(list.frame(for: row)))"
        }
        let rowViews = views(SidebarRowView.self, in: list).filter { shows($0, in: list) }
            .map { view in
                let frame = view.convert(view.bounds, to: list)
                let tracked = list.rowViews[view.key] === view ? "" : " untracked"
                return "\(name(view.key)) \(r(frame)) alpha \(r(view.alphaValue))\(view.isSelected ? " selected" : "")\(tracked)"
            }
            .sorted()
        let rails = views(GroupLineView.self, in: list).filter { shows($0, in: list) }
            .map { "\(r($0.convert($0.bounds, to: list))) alpha \(r($0.alphaValue)) \($0.color)" }
            .sorted()
        let railModel = list.groupLineViews.lines.map { "\($0.group.rawValue) \(r($0.frame)) \($0.color)" }
        let state = ["selected \(list.selectedRowKey.map(name) ?? "-")", "suppressed \(list.suppressed.map(name).sorted())",
                     "gap \(list.displayed.gapY.map { r($0) } ?? "-")", "drag \(list.drag != nil) settling \(list.settling != nil) landing \(list.landing != nil)"]
        return Snapshot(layout: layout, rowViews: rowViews, rails: rails, railModel: railModel, state: state)
    }

    /// Whether a spring, fade or flight still runs in `view`'s layer tree.
    static func animates(_ view: NSView) -> Bool {
        func runs(_ layer: CALayer) -> Bool { !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: runs) }
        return view.layer.map(runs) ?? false
    }

    /// Lets the list's completions run (a landing's end, a deferred reload) and, with motion on, its springs and fades
    /// end (a rebuild draws ends, not flights), then compares it with a fresh rebuild. A row's spring
    /// (`NSAnimationContext` with a SwiftUI spring) writes its frame on each display frame and leaves no layer
    /// animation to see, so the list waits until it equals the rebuild, no layer animation runs and no row fades
    /// (at most 10 s: a list stuck mid-flight still differs). Two equal looks 50 ms apart are no sign of an end: on a
    /// loaded runner a spring can miss every display frame between them and stop half a point short.
    ///
    /// The completions run in three main-thread turns (`turn`), not three 30 ms sleeps: queued work needs a turn, not
    /// a clock, and anything that needs time (a spring, a fade, a flight's end) keeps the wait below going. The wait
    /// ends at the first look that matches; nothing on the main thread changes between two looks with no await
    /// between them. On cmux7s the three sleeps took 90 to 440 ms per check and the 200 looks after a match 100 to
    /// 130 ms: 37 of this suite's 45 s and 100 of `SidebarIncrementalMatchesRebuildGapsTests`' 122 s.
    static func expectMatchesRebuild(_ sidebar: SidebarView, _ when: String) async {
        let list = sidebar.list
        let d0 = CACurrentMediaTime()
        for _ in 0..<3 {
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            sidebar.renderNow()
            await turn(sidebar.window)
        }
        let d1 = CACurrentMediaTime()
        let (fresh, window) = rebuilt(from: list.model, design: sidebar.design)
        let d2 = CACurrentMediaTime()
        defer { window.close() }
        let theirs = snapshot(fresh.list)
        let d3 = CACurrentMediaTime()
        let deadline = ContinuousClock.now + .seconds(10)
        var sleeps = 0, differs = 0, anim = 0
        while snapshot(list) != theirs || animates(list) || !list.fadingRows.isEmpty, ContinuousClock.now < deadline {
            sleeps += 1
            if snapshot(list) != theirs { differs += 1 }
            if animates(list) { anim += 1 }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let d4 = CACurrentMediaTime()
        print(String(format: "MATCH-REBUILD-DIAG3 %@ settle=%.1f rebuild=%.1f snap=%.1f poll=%.1f sleeps=%d differs=%d anim=%d since-last=%.1f", when, (d1 - d0) * 1000, (d2 - d1) * 1000, (d3 - d2) * 1000, (d4 - d3) * 1000, sleeps, differs, anim, (d0 - Self.lastEnd) * 1000))
        defer { Self.lastEnd = CACurrentMediaTime() }
        let mine = snapshot(list)
        #expect(mine == theirs, "\(when): the list differs from a fresh rebuild (+ only on screen, - only in the rebuild):\n\(mine.diff(theirs))")
    }

    /// One main-thread turn, no clock: main-actor tasks and main-queue blocks queued before it run (the await), the
    /// run loop's due sources and timers fire, then `window` lays out, draws and commits, which runs the completion
    /// blocks of changes that did not animate.
    nonisolated(unsafe) static var lastEnd = CACurrentMediaTime()
    static func turn(_ window: NSWindow?) async {
        await Task.yield()
        runLoopPassAndCommit(window)
    }

    /// The synchronous half of `turn`: one run loop pass that does not wait, then `window`'s layout, display and commit.
    static func runLoopPassAndCommit(_ window: NSWindow?) {
        RunLoop.main.run(mode: .default, before: Date())
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    // MARK: Operations

    /// Lifts `key` and drags it `dy` points in eight steps, then lets go.
    static func drag(_ list: SidebarListView, _ key: SidebarRowKey, by dy: CGFloat) throws {
        let row = try #require(list.displayed.row(for: key), "no row \(name(key))")
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "\(name(key)) did not lift")
        for step in 1...8 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 8), to: nil))
        }
        list.finishDrag()
    }

    static func row(_ list: SidebarListView, _ key: SidebarRowKey) throws -> SidebarRow {
        try #require(list.displayed.row(for: key), "no row \(name(key)): \(snapshot(list).layout)")
    }

    static func group(_ id: GroupID) -> SidebarRowKey { .group(id) }
    static func workspace(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    /// Runs `operation` and the daemon's echo of it.
    static func run(_ operation: Operation, _ sidebar: SidebarView, _ doc: Doc) async throws {
        let list = sidebar.list, model = list.model
        switch operation {
        case .groupPastEmptyGroup:
            // #23182: Infra's header down until the card's top is past the empty group's middle.
            let header = try row(list, group(infra)), emptyRow = try row(list, group(empty))
            try drag(list, header.key, by: emptyRow.maxY + header.height - (header.y + header.height / 2))
        case .groupPastFoldedGroup:
            // Work folds, Infra goes up past it, Work opens.
            model.send(.toggleCollapse(.group(work)))
            await expectMatchesRebuild(sidebar, "after Work folds")
            let header = try row(list, group(infra)), workRow = try row(list, group(work))
            try drag(list, header.key, by: workRow.y + 2 - header.y)
        case .foldedGroupUp:
            let header = try row(list, group(folded)), infraRow = try row(list, group(infra))
            try drag(list, header.key, by: infraRow.y + 2 - header.y)
        case .reorderInGroup:
            let api = try row(list, workspace("api")), docs = try row(list, workspace("docs"))
            try drag(list, api.key, by: docs.y + 2 - api.y)
        case .looseIntoGroup:
            let loose = try row(list, workspace("loose2")), docs = try row(list, workspace("docs"))
            try drag(list, loose.key, by: docs.y + docs.height / 2 + 2 - loose.maxY)
        case .memberOutOfGroup:
            let deploy = try row(list, workspace("deploy")), scratch = try row(list, workspace("scratch"))
            try drag(list, deploy.key, by: scratch.y + 2 - deploy.y)
        case .tabAcrossGroups:
            // A tab from a pane: over the folded group (it springs open), then into Work between docs and web.
            list.springLoadDelay = .zero
            let foldedRow = try row(list, group(folded))
            _ = list.externalDragMoved(windowPoint: list.convert(NSPoint(x: 80, y: foldedRow.y + foldedRow.height / 2), to: nil), sourceMachine: nil)
            try? await Task.sleep(for: .milliseconds(50))
            await expectMatchesRebuild(sidebar, "after the folded group springs open")
            let web = try row(list, workspace("web"))
            _ = list.externalDragMoved(windowPoint: list.convert(NSPoint(x: 80, y: web.y), to: nil), sourceMachine: nil)
            let drop = list.externalDragEnded()
            // The gap showed on web's top edge: the tab lands in Work between docs and web.
            #expect(drop == .newWorkspace(section: .machine(.local), group: work, index: 1), "the tab drag proposed \(String(describing: drop))")
            switch drop {
            case let .newWorkspace(_, group?, index): model.sections = doc.sections(model, adding: (group, "moved", index))
            case let .intoGroup(group): model.sections = doc.sections(model, adding: (group, "moved", nil))
            default: break
            }
            sidebar.renderNow()
            let landed = list.displayed.rows.filter { $0.group == work }.compactMap { row -> String? in
                if case let .workspace(id) = row.key { id.rawValue } else { nil }
            }
            #expect(landed == ["docs", "moved", "web", "api"], "the tab's workspace landed in Work as \(landed)")
            return
        }
        #expect(!doc.drops.isEmpty, "\(operation.rawValue): the drag dropped nothing: \(snapshot(list).layout)")
        // The card lands, then the echo: the document's new order, as the app's model change shows it.
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        model.sections = doc.sections(model)
        sidebar.renderNow()
        if operation == .groupPastFoldedGroup {
            await expectMatchesRebuild(sidebar, "after the drop past folded Work")
            model.send(.toggleCollapse(.group(work)))
        }
    }

    @Test(arguments: Operation.allCases)
    func theListMatchesAFreshRebuildAfterEachOperation(_ operation: Operation) async throws {
        // The spring's end at once; a rebuild draws ends, not flights. `SidebarIncrementalMatchesRebuildGapsTests` runs motion.
        try await Self.check(operation, reduceMotion: true)
    }

    /// `operation` from rest, then each group's fold and a click in and out of a group, each matched against a rebuild.
    static func check(_ operation: Operation, reduceMotion: Bool) async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = previousMotion }
        let doc = Doc()
        let (sidebar, window) = Self.fixture(doc)
        defer { window.close() }
        await Self.expectMatchesRebuild(sidebar, "at rest")
        try await Self.run(operation, sidebar, doc)
        await Self.expectMatchesRebuild(sidebar, "after \(operation.rawValue)")
        await Self.foldsAndClicks(sidebar, after: operation.rawValue, clicking: ["web", "f1", "scratch"])
    }

    /// Each of `groups` folds and opens, then each of `ids` is clicked, each matched against a rebuild.
    static func foldsAndClicks(_ sidebar: SidebarView, after: String, groups: [GroupID] = allGroups, clicking ids: [String]) async {
        for group in groups where sidebar.list.model.group(group) != nil {
            sidebar.list.model.send(.toggleCollapse(.group(group)))
            await Self.expectMatchesRebuild(sidebar, "after \(after), then \(group.rawValue) toggles")
            sidebar.list.model.send(.toggleCollapse(.group(group)))
            await Self.expectMatchesRebuild(sidebar, "after \(after), then \(group.rawValue) toggles back")
        }
        for id in ids where sidebar.list.model.workspace(WorkspaceID(id)) != nil {
            sidebar.list.model.click(WorkspaceID(id))
            await Self.expectMatchesRebuild(sidebar, "after \(after), then a click on \(id)")
        }
    }
}
