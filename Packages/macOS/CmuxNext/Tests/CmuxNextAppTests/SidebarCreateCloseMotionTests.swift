import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Leo 2026-11-22, with a recording of the Mac sidebar: "the sidebar workspace creation is just [broken] again.
/// stupid [...] animation. idk what logic we have but just [...] do it properly, and do the animations properly."
/// In the recording he clicks + in the sidebar header: the Leads group's rows vanish and leave a blank gap, the new
/// workspace appears selected below the gap, then the rows snap back with it in place. He closes it: the rows jump
/// again and the selection highlight sits on two rows for a moment.
///
/// A frame-level detector over the real path (`SidebarView.render`, the model's set, the list's reload): a sidebar
/// with loose rows and an open group of agent leads is sampled on every display frame while one workspace is created
/// (selected, as + does) and then closed, with and without the session tree drawn (lineage nesting: a lead with a
/// sub-session). In every frame:
/// - every row that was drawn before and stays listed is the same view, in the list, not hidden, at full opacity
///   (no blank frame, no view swapped under a row);
/// - its y moves one way from where it was to where it ends (no jump back, no overshoot past either end);
/// - every listed row in the visible part of the list has a view (no blank slot);
/// - at most one row draws the selection.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCreateCloseMotionTests {
    typealias Flicker = SidebarGroupFlickerTests
    typealias Piece = SidebarGroupFlickerTests.Piece

    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let leads = GroupID("g-leads")
    static let above = ["a", "b"].map(WorkspaceID.init)
    /// The group's rows: three leads, two of them with a sub-session listed after its lead.
    static let members = ["lead-1", "sub-1", "lead-2", "sub-2", "lead-3"].map(WorkspaceID.init)
    static let below = ["c", "d", "e"].map(WorkspaceID.init)
    static let new = WorkspaceID("workspace-427")
    /// Lineage: each sub-session under its lead (what `SidebarSessionTreeFeed` publishes for agent-started sessions).
    static let parents: [WorkspaceID: WorkspaceID] = [members[1]: members[0], members[3]: members[2]]

    nonisolated enum Place: String, CaseIterable, Sendable {
        case top = "at the top", aboveGroup = "right above the group", inGroup = "inside the group", belowGroup = "right below the group",
             bottom = "at the bottom"
    }

    /// The row selected before the create.
    nonisolated enum Selected: String, CaseIterable, Sendable {
        case lead = "a lead selected", child = "a sub-session selected", loose = "a loose row selected", nothing = "nothing selected"
        var id: WorkspaceID? {
            switch self {
            case .lead: WorkspaceID("lead-2")
            case .child: WorkspaceID("sub-1")
            case .loose: WorkspaceID("a")
            case .nothing: nil
            }
        }
    }

    static func ws(_ id: WorkspaceID) -> SidebarWorkspace { SidebarWorkspace(id: id, title: id.rawValue) }

    static func sections(new place: Place? = nil, closed: Bool = false) -> [SidebarSection] {
        let added: [SidebarNode] = [.workspace(ws(new))]
        var nodes: [SidebarNode] = place == .top ? added : []
        nodes += above.map { .workspace(ws($0)) }
        if place == .aboveGroup { nodes += added }
        nodes.append(.group(SidebarGroup(id: leads, name: "Leads", color: .blue, isCollapsed: closed,
                                         workspaces: (members + (place == .inGroup ? [new] : [])).map(ws))))
        if place == .belowGroup { nodes += added }
        nodes += below.map { .workspace(ws($0)) }
        if place == .bottom { nodes += added }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func make(selected: WorkspaceID?, closed: Bool) -> (SidebarModel, SidebarView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(closed: closed), activeWorkspaceID: selected)
        model.selection = selected.map { [$0] } ?? []
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        sidebar.list.leftButtonIsDown = { false }
        sidebar.list.pointerIsOverList = { _ in false }
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        sidebar.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (model, sidebar, window)
    }

    // MARK: Observables

    /// One frame: every listed row's view as drawn, the rows drawing the selection, and the listed rows in the visible
    /// part of the list that have no view.
    struct Frame {
        var rows: [SidebarRowKey: Piece] = [:]
        var selected: [String] = []
        var blank: [String] = []
    }

    static func name(_ key: SidebarRowKey) -> String {
        switch key {
        case let .workspace(id): id.rawValue
        case let .group(id): "group \(id.rawValue)"
        default: "\(key)"
        }
    }

    static func sample(_ list: SidebarListView, flipped: Bool) -> Frame {
        var frame = Frame()
        let visible = list.visibleRect
        for row in list.displayed.rows {
            let view = list.rowViews[row.key]
            frame.rows[row.key] = Flicker.piece(view: view, in: list, flipped: flipped)
            // A slot inside the visible part of the list (a point clear of its edges) with no view to draw it.
            if view == nil, list.frame(for: row).insetBy(dx: 0, dy: 2).intersects(visible.insetBy(dx: 0, dy: 2)) { frame.blank.append(name(row.key)) }
        }
        // Every row view the list still draws (a leaving one too) that paints the selection.
        for view in list.subviews.compactMap({ $0 as? SidebarRowView }) where view.isSelected && !view.isHidden {
            guard let layer = view.layer, Flicker.presented(layer).opacity > 0.01 else { continue }
            let key = list.rowViews.first { $0.value === view }?.key
            frame.selected.append(key.map(name) ?? "a leaving row at y \(Piece.f(view.frame.minY))")
        }
        return frame
    }

    // MARK: Run

    nonisolated struct Run: Sendable, CustomTestStringConvertible {
        var place: Place
        var tree = false
        var selected = Selected.lead
        /// The Leads group is closed: it draws its header, and its selected member if it has one.
        var groupClosed = false
        var intent = true
        var newWorkspace = false
        /// The daemon lists the row at the bottom first and the app places it two frames later (a placement's move).
        var placedLater = false
        var testDescription: String {
            "\(newWorkspace ? "[newWorkspace motion] " : "")create \(place.rawValue), then close"
                + "\(tree ? " [session tree]" : "") [\(selected.rawValue)]\(groupClosed ? " [group closed]" : "")"
                + "\(intent ? "" : " (calm)")\(placedLater ? " [listed at the bottom, placed 2 frames later]" : "")"
        }

        static var all: [Run] {
            var runs: [Run] = []
            for tree in [true, false] {
                for place in Place.allCases {
                    runs.append(Run(place: place, tree: tree))
                }
                for selected in [Selected.child, .loose, .nothing] {
                    for place in [Place.inGroup, .belowGroup, .bottom] { runs.append(Run(place: place, tree: tree, selected: selected)) }
                }
                for selected in [Selected.lead, .loose, .nothing] {
                    for place in [Place.inGroup, .belowGroup, .bottom] { runs.append(Run(place: place, tree: tree, selected: selected, groupClosed: true)) }
                }
                runs.append(Run(place: .belowGroup, tree: tree, intent: false))
                runs.append(Run(place: .belowGroup, tree: tree, newWorkspace: true))
                runs.append(Run(place: .top, tree: tree, newWorkspace: true))
                runs.append(Run(place: .belowGroup, tree: tree, placedLater: true))
            }
            return runs
        }
    }

    /// The failures of one phase (a create or a close): `frames` sampled from the change on, `applies` at each apply,
    /// between the settled `before` and `after`. `skip`: the row that comes or goes (it opens, or closes, by design).
    static func check(_ phase: String, before: Frame, frames: [Frame], applies: [(Int, Frame)], after: Frame, skip: SidebarRowKey,
                      turn: Int?, failures: inout [String]) {
        func fail(_ index: Int, _ what: String) { failures.append("\(phase), frame \(index): \(what)") }
        func monotonic(_ name: String, _ ys: ArraySlice<CGFloat>, start: CGFloat, end: CGFloat) {
            let lo = min(start, end) - 0.5, hi = max(start, end) + 0.5
            var previous = start
            for (index, y) in zip(ys.indices, ys) where !y.isNaN {
                if y < lo || y > hi { fail(index, "\(name) y \(Piece.f(y)) outside start \(Piece.f(start)) .. end \(Piece.f(end))") }
                let back = end >= start ? previous - y : y - previous
                if back > 0.5 { fail(index, "\(name) y jumped back \(Piece.f(previous)) -> \(Piece.f(y)) (start \(Piece.f(start)), end \(Piece.f(end)))") }
                previous = y
            }
        }
        let kept = before.rows.filter { $0.key != skip && $0.value.shown && after.rows[$0.key]?.shown == true }
        for (index, frame) in applies {
            for (key, was) in kept {
                let now = frame.rows[key] ?? Piece()
                if now.object != was.object || !now.shown { fail(index, "at apply: \(name(key)) view replaced, removed or hidden (\(now))") }
            }
        }
        for (index, frame) in frames.enumerated() {
            for (key, was) in kept {
                let now = frame.rows[key] ?? Piece()
                if now.object != was.object { fail(index, "\(name(key)) view replaced or gone (\(now))") }
                if !now.shown { fail(index, "\(name(key)) detached or hidden (\(now))") }
                if now.alpha < 0.99 { fail(index, "\(name(key)) alpha \(now.alpha) (\(now))") }
            }
            if !frame.blank.isEmpty { fail(index, "blank slots, no view: \(frame.blank.sorted())") }
            if frame.selected.count > 1 { fail(index, "\(frame.selected.count) rows draw the selection: \(frame.selected.sorted())") }
        }
        for (key, was) in kept {
            guard let end = after.rows[key] else { continue }
            let ys = frames.map { $0.rows[key]?.minY ?? .nan }
            // A placement two frames later takes the first change back: two legs, each one way.
            if let turn, ys.count > turn + 1, !ys[turn].isNaN {
                monotonic(name(key), ys[...turn], start: was.minY, end: ys[turn])
                monotonic(name(key), ys[(turn + 1)...], start: ys[turn], end: end.minY)
            } else {
                monotonic(name(key), ys[...], start: was.minY, end: end.minY)
            }
        }
    }

    static func run(_ run: Run, log: inout [String]) -> [String] {
        let selected = run.selected.id
        let (model, sidebar, window) = make(selected: selected, closed: run.groupClosed)
        defer { window.close() }
        let list = sidebar.list
        let label = run.testDescription
        guard let header = list.rowViews[.group(leads)], let headerLayer = header.layer else { return ["\(label): no group header after the first layout"] }
        let flipped = abs(headerLayer.frame.minY - header.frame.minY) > 0.5
        let key = SidebarRowKey.workspace(new)
        var failures: [String] = []
        var frames: [Frame] = []
        var applies: [(Int, Frame)] = []
        list.onApply = { _ in applies.append((frames.count, sample(list, flipped: flipped))) }
        func settle() -> Frame {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            Flicker.step(list)
            return sample(list, flipped: flipped)
        }
        func show(_ change: () -> Void, then later: (() -> Void)? = nil) {
            (frames, applies) = ([], [])
            if run.intent { model.noteUserIntent() }
            change()
            sidebar.renderNow()
            list.layoutSubtreeIfNeeded()
            CATransaction.flush()
            frames.append(sample(list, flipped: flipped))
            for index in 1...30 {
                if let later, index == 2 {
                    later()
                    sidebar.renderNow()
                }
                Flicker.step(list)
                frames.append(sample(list, flipped: flipped))
            }
        }
        func trace(_ phase: String, _ keys: [SidebarRowKey]) {
            let lines = keys.map { key in
                "\(name(key)) " + frames.prefix(10).map { f in f.rows[key].map { $0.shown ? "\(Piece.f($0.minY))@\(String(format: "%.2f", $0.alpha))" : "-" } ?? "x" }.joined(separator: " ")
            }
            log.append("\(label), \(phase): applies \(applies.count), selected by frame \(frames.prefix(6).map(\.selected))\n  " + lines.joined(separator: "\n  "))
        }
        let traced: [SidebarRowKey] = [.workspace(above[1]), .group(leads), .workspace(members[0]), .workspace(members[4]), .workspace(below[0]), key]

        // The create, as + makes it: the new row listed and selected in one set.
        let before = sample(list, flipped: flipped)
        if before.selected != (selected.map { [name(.workspace($0))] } ?? []) { failures.append("\(label): before the create the selection draws on \(before.selected)") }
        show({
            model.setSections(sections(new: run.placedLater ? .bottom : run.place, closed: run.groupClosed))
            model.activeWorkspaceID = new
            model.selection = [new]
        }, then: run.placedLater ? { model.setSections(sections(new: run.place, closed: run.groupClosed)) } : nil)
        let created = settle()
        trace("create", traced)
        check("\(label), create", before: before, frames: frames, applies: applies, after: created, skip: key,
              turn: run.placedLater ? 1 : nil, failures: &failures)
        if created.rows[key]?.shown != true || (created.rows[key]?.alpha ?? 0) < 0.99 {
            failures.append("\(label), create: the new row is not drawn once settled (\(created.rows[key] ?? Piece()))")
        }
        if created.selected != [name(key)] { failures.append("\(label), create: once settled the selection draws on \(created.selected)") }
        // The new row, once it shows, never goes away again and moves one way to its slot.
        if let end = created.rows[key], end.shown, !run.placedLater {
            let first = frames.firstIndex { $0.rows[key]?.shown == true }
            if first != 0 { failures.append("\(label), create: the new row first shows in frame \(first.map(String.init) ?? "none"), not with the change") }
            if let first {
                for (index, frame) in frames.enumerated().dropFirst(first) where frame.rows[key]?.shown != true {
                    failures.append("\(label), create, frame \(index): the new row went away again")
                }
            }
        }

        // The close: the row leaves and the selection moves to its neighbour, in one step.
        show({ model.apply(.close([new])) })
        let closed = settle()
        trace("close", traced)
        check("\(label), close", before: created, frames: frames, applies: applies, after: closed, skip: key, turn: nil, failures: &failures)
        if closed.rows[key] != nil { failures.append("\(label), close: the closed row is still listed") }
        if closed.selected.count > 1 { failures.append("\(label), close: once settled the selection draws on \(closed.selected)") }
        // Every row is back where it started.
        for (rowKey, was) in before.rows where was.shown {
            guard let end = closed.rows[rowKey], end.shown else { failures.append("\(label), close: \(name(rowKey)) is not drawn once settled"); continue }
            if abs(end.minY - was.minY) > 0.5 { failures.append("\(label), close: \(name(rowKey)) ends at y \(Piece.f(end.minY)), was \(Piece.f(was.minY))") }
        }
        return failures
    }

    @Test(arguments: Run.all) func aCreateAndACloseMoveEachRowOnce(_ run: Run) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let kinds = DesignSettings.shared.enabledAnimations
        defer { DesignSettings.shared.enabledAnimations = kinds }
        if run.newWorkspace { DesignSettings.shared.enabledAnimations.insert(.newWorkspace) }
        let tree = SidebarSessionTree.shared.state
        defer { SidebarSessionTree.shared.state = tree }
        SidebarSessionTree.shared.state = run.tree ? SidebarSessionTreeState(parents: Self.parents) : nil
        var log = ["animatesMovement \(Motion.sidebar.animatesMovement), screens \(NSScreen.screens.count)"]
        let failures = Self.run(run, log: &log)
        print("SidebarCreateCloseMotion log:\n" + log.joined(separator: "\n"))
        for failure in failures { print("ROWMOTIONFAIL \(failure)") }
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(60).joined(separator: "\n"))")
    }
}
