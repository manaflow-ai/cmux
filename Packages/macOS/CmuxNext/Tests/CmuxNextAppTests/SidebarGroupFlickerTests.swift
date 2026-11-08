import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Leo 2026-11-08: "there's the sidebar where when things maybe open or shift a bit, there's like still a bit of a
/// flicker on that, like individual top group". A frame-level repro: the top group of the list (an open, colored
/// group with three members) is sampled on every display frame while the rows open or shift around it, through the
/// paths the app uses (a structural set, a row patch, a fold, a selection). In every frame its header view is the same
/// instance, shown at full opacity; its y moves one way from start to end; its bar fill, glass rim and members' rail
/// are present at full opacity and move with the header; and no member row disappears or blinks.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupFlickerTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let top = GroupID("g-top")
    static let lower = GroupID("g-lower")
    static let members = ["m1", "m2", "m3"].map(WorkspaceID.init)
    static let loose = ["a", "b", "c"].map(WorkspaceID.init)
    static let lowerMembers = ["l1", "l2"].map(WorkspaceID.init)
    static let tail = WorkspaceID("d")

    static func ws(_ id: WorkspaceID) -> SidebarWorkspace { SidebarWorkspace(id: id, title: id.rawValue) }

    /// The top group (blue, open), three loose rows, a second group (green, collapsed), one more loose row.
    static let fresh = GroupID("g-new")
    static let freshMembers = ["n1", "n2"].map(WorkspaceID.init)

    static func nodes(topCollapsed: Bool = false, lowerCollapsed: Bool = true, above: [WorkspaceID] = [], below: [WorkspaceID] = [],
                      patched: [WorkspaceID: SidebarWorkspace] = [:], newGroup: Bool = false, loose: [WorkspaceID] = Self.loose) -> [SidebarNode] {
        func row(_ id: WorkspaceID) -> SidebarWorkspace { patched[id] ?? ws(id) }
        return above.map { .workspace(row($0)) }
            + (newGroup ? [.group(SidebarGroup(id: fresh, name: "New", color: .orange, workspaces: freshMembers.map(row)))] : [])
            + [.group(SidebarGroup(id: top, name: "Top", color: .blue, isCollapsed: topCollapsed, workspaces: members.map(row)))]
            + below.map { .workspace(row($0)) }
            + loose.map { .workspace(row($0)) }
            + [.group(SidebarGroup(id: lower, name: "Lower", color: .green, isCollapsed: lowerCollapsed, workspaces: lowerMembers.map(row)))]
            + [.workspace(row(tail))]
    }

    static func make(topCollapsed: Bool = false, lowerCollapsed: Bool = true, selected: WorkspaceID = members[0],
                     expanded: Bool = false) -> (SidebarModel, SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes(topCollapsed: topCollapsed, lowerCollapsed: lowerCollapsed))],
                                 activeWorkspaceID: selected)
        model.selection = [selected]
        // Expanded density: a row with something to say draws a second line, so a status grows it (the default
        // density draws no status line, Lawrence 2026-10-21).
        model.expanded = expanded
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        list.leftButtonIsDown = { false }
        list.pointerIsOverList = { _ in false }
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (model, list, window)
    }

    // MARK: Observables

    /// One piece as drawn: its object, whether it is in the list, hidden, its drawn opacity and its y span in the
    /// list's coordinates (header, rail, members), or, for a piece inside the header (bar fill, rim), in the header's.
    struct Piece: CustomStringConvertible {
        var object: ObjectIdentifier?
        var attached = false
        var hidden = true
        var alpha: Float = 0
        var minY: CGFloat = .nan
        var maxY: CGFloat = .nan
        var shown: Bool { object != nil && attached && !hidden }
        var description: String {
            object == nil ? "absent" : "y \(Self.f(minY))..\(Self.f(maxY)) alpha \(alpha)\(hidden ? " hidden" : "")\(attached ? "" : " detached")"
        }
        static func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    }

    struct Frame {
        var header = Piece(), fill = Piece(), rim = Piece(), rail = Piece()
        var members: [WorkspaceID: Piece] = [:]
    }

    static func presented(_ layer: CALayer) -> CALayer { layer.presentation() ?? layer }

    /// A layer's drawn y span in `container`'s view coordinates (flipped or not).
    static func span(_ layer: CALayer, in container: CALayer, flipped: Bool) -> (CGFloat, CGFloat) {
        let frame = presented(layer).frame
        guard flipped else { return (frame.minY, frame.maxY) }
        let height = container.bounds.height
        return (height - frame.maxY, height - frame.minY)
    }

    static func piece(view: NSView?, in list: SidebarListView, flipped: Bool) -> Piece {
        guard let view, let layer = view.layer, let container = list.layer else { return Piece() }
        let (minY, maxY) = span(layer, in: container, flipped: flipped)
        return Piece(object: ObjectIdentifier(view), attached: view.superview === list, hidden: view.isHidden || layer.isHidden || view.isHiddenOrHasHiddenAncestor,
                     alpha: presented(layer).opacity, minY: minY, maxY: maxY)
    }

    /// The rail of the top group: the group line view at the frame the line views show for it.
    static func rail(_ list: SidebarListView, _ group: GroupID = top) -> GroupLineView? {
        guard let frame = list.groupLineViews.shown[group]?.frame else { return nil }
        return list.subviews.lazy.compactMap { $0 as? GroupLineView }.first { $0.frame == frame }
    }

    static func sample(_ list: SidebarListView, flipped: Bool, group: GroupID = top, members: [WorkspaceID] = members) -> Frame {
        var frame = Frame()
        let header = list.rowViews[.group(group)] as? GroupHeaderRowView
        frame.header = piece(view: header, in: list, flipped: flipped)
        if let header, let headerLayer = header.layer {
            // Inside the header: the header's own layer space (its sublayers move with it).
            let fill = presented(header.pill)
            frame.fill = Piece(object: ObjectIdentifier(header.pill), attached: header.pill.superlayer === headerLayer, hidden: header.pill.isHidden,
                               alpha: fill.opacity, minY: fill.frame.minY, maxY: fill.frame.maxY)
            if let rimLayer = header.rim.layer {
                let rim = presented(rimLayer)
                frame.rim = Piece(object: ObjectIdentifier(header.rim), attached: header.rim.superview === header,
                                  hidden: header.rim.isHidden || rimLayer.isHidden, alpha: rim.opacity, minY: rim.frame.minY, maxY: rim.frame.maxY)
            }
        }
        frame.rail = piece(view: rail(list, group), in: list, flipped: flipped)
        for id in members { frame.members[id] = piece(view: list.rowViews[.workspace(id)], in: list, flipped: flipped) }
        return frame
    }

    // MARK: Events

    enum Event: String, CaseIterable {
        case insertBelow = "a: a new workspace below the top group"
        case insertAbove = "b: a new workspace above the top group"
        case memberGrows = "c: a member gains a status block"
        case looseGrows = "d: a loose row below grows"
        case lowerOpens = "e: the second group opens"
        case selectElsewhere = "f: a row elsewhere is selected"
        case selectedPassesOver = "i: the selected row moves up past the top group"
        case topFolds = "j: the top group folds, the second group open below it"
        static let first: [Event] = [.insertBelow, .insertAbove, .memberGrows, .looseGrows, .lowerOpens, .selectElsewhere]
    }

    static func grown(_ id: WorkspaceID) -> SidebarWorkspace {
        var row = ws(id)
        row.status = "Building"
        row.reported = SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building"), .init(key: "tests", text: "412 passed")],
                                              log: .init(level: .info, text: "compiling"))
        return row
    }

    /// Applies `event` the way the app does: `intent` is a change the user asked for (it moves rows on the spring);
    /// without it the change shows calmly, in one step.
    static func apply(_ event: Event, _ model: SidebarModel, _ list: SidebarListView, intent: Bool) {
        if intent { model.noteUserIntent() }
        switch event {
        case .insertBelow, .insertAbove:
            let new = WorkspaceID("new")
            model.sections = [SidebarSection(kind: .machine(machine), nodes: nodes(above: event == .insertAbove ? [new] : [],
                                                                                   below: event == .insertBelow ? [new] : []))]
            list.showModelChange(animates: true) // SidebarView's observation of a structural set
        case .memberGrows:
            if !model.patchWorkspaces([grown(members[1])]) { list.showModelChange(animates: true) }
        case .looseGrows:
            if !model.patchWorkspaces([grown(loose[0])]) { list.showModelChange(animates: true) }
        case .lowerOpens:
            model.setGroupCollapsed(lower, false)
        case .selectElsewhere:
            let old = model.selectedItem, oldSelection = model.selection
            model.activeWorkspaceID = loose[1]
            model.selection = [loose[1]]
            if !list.patchSelection(from: old, oldSelection: oldSelection) { list.reload(animated: intent, fromModel: true) }
        case .selectedPassesOver:
            // A re-sort or a move puts the selected row `b` above the top group.
            model.sections = [SidebarSection(kind: .machine(machine), nodes: nodes(above: [loose[1]], loose: [loose[0], loose[2]]))]
            list.showModelChange(animates: true)
        case .topFolds:
            model.setGroupCollapsed(top, true)
        }
    }

    static func step(_ list: SidebarListView) {
        list.layoutSubtreeIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }

    // MARK: Checks

    /// Every frame's failures for one run of `event`.
    static func run(_ event: Event, intent: Bool, topCollapsed: Bool = false, then second: Event? = nil, log: inout [String]) -> [String] {
        let (model, list, window) = make(topCollapsed: topCollapsed, lowerCollapsed: event != .topFolds,
                                         selected: event == .selectedPassesOver ? loose[1] : members[0],
                                         expanded: [.memberGrows, .looseGrows].contains(event) || [.memberGrows, .looseGrows].contains(second))
        defer { window.close() }
        let label = "\(event.rawValue)\(second.map { " + \($0.rawValue) 2 frames later" } ?? "")\(intent ? " (user intent)" : " (calm)")\(topCollapsed ? " [top collapsed]" : "")"
        guard let headerView = list.rowViews[.group(top)], let headerLayer = headerView.layer else {
            return ["\(label): no top group header after the first layout"]
        }
        // Whether the list's layer space runs up (AppKit flips a flipped view's sublayers' geometry for it).
        let flipped = abs(headerLayer.frame.minY - headerView.frame.minY) > 0.5
        let before = sample(list, flipped: flipped)
        var applies = 0
        var frames: [Frame] = []
        var applyFrames: [(Int, Frame)] = []
        list.onApply = { _ in
            applies += 1
            applyFrames.append((frames.count, sample(list, flipped: flipped)))
        }
        apply(event, model, list, intent: intent)
        list.layoutSubtreeIfNeeded()
        CATransaction.flush()
        frames.append(sample(list, flipped: flipped))
        for index in 1...30 {
            if let second, index == 2 { apply(second, model, list, intent: intent) }
            step(list)
            frames.append(sample(list, flipped: flipped))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        step(list)
        let after = sample(list, flipped: flipped)

        var failures: [String] = []
        func fail(_ index: Int, _ what: String) { failures.append("\(label), frame \(index): \(what)") }
        func monotonic(_ name: String, _ ys: [CGFloat], start: CGFloat, end: CGFloat) {
            let lo = min(start, end) - 0.5, hi = max(start, end) + 0.5
            var previous = start
            for (index, y) in ys.enumerated() where !y.isNaN {
                if y < lo || y > hi { fail(index, "\(name) y \(Piece.f(y)) outside start \(Piece.f(start)) .. end \(Piece.f(end))") }
                let back = end >= start ? previous - y : y - previous
                if back > 0.5 { fail(index, "\(name) y jumped back \(Piece.f(previous)) -> \(Piece.f(y)) (start \(Piece.f(start)), end \(Piece.f(end)))") }
                previous = y
            }
        }

        let headerHeight = before.header.maxY - before.header.minY
        let railOffset = before.rail.minY - before.header.minY
        let folds = event == .topFolds || second == .topFolds
        // The list as `apply` hands it over (before the frame commits): the header is the same view, shown.
        for (index, frame) in applyFrames {
            let h = frame.header
            if h.object != before.header.object { fail(index, "at apply: header view replaced or gone (\(h))") }
            if !h.shown { fail(index, "at apply: header removed or hidden (\(h))") }
        }
        for (index, frame) in frames.enumerated() {
            let h = frame.header
            // The rail draws with its header: never brighter or dimmer than the bar (a pass-over fade, a new line's fade).
            if frame.rail.shown, h.shown, abs(frame.rail.alpha - h.alpha) > 0.05 {
                fail(index, "rail alpha \(frame.rail.alpha), header alpha \(h.alpha) (rail \(frame.rail), header \(h))")
            }
            if folds { continue }
            if h.object != before.header.object { fail(index, "header view replaced or gone (\(h))") }
            if !h.attached { fail(index, "header removed from the list (\(h))") }
            if h.hidden { fail(index, "header hidden (\(h))") }
            if h.alpha < 0.99 { fail(index, "header alpha \(h.alpha) (\(h))") }
            if abs((h.maxY - h.minY) - headerHeight) > 0.5 { fail(index, "header height \(Piece.f(h.maxY - h.minY)), was \(Piece.f(headerHeight))") }
            // The pieces drawn before stay drawn, at full opacity, with the header.
            for (name, was, now) in [("bar fill", before.fill, frame.fill), ("glass rim", before.rim, frame.rim)] where was.shown {
                if !now.shown { fail(index, "\(name) gone or hidden (\(now))") }
                if now.alpha < 0.99 { fail(index, "\(name) alpha \(now.alpha)") }
                if abs(now.minY - was.minY) > 0.5 { fail(index, "\(name) at y \(Piece.f(h.minY + now.minY)), header y \(Piece.f(h.minY)) (offset \(Piece.f(now.minY)), was \(Piece.f(was.minY)))") }
            }
            if before.rail.shown {
                let r = frame.rail
                if r.object != before.rail.object { fail(index, "rail replaced or gone (\(r), header y \(Piece.f(h.minY)))") }
                if !r.shown { fail(index, "rail detached or hidden (\(r))") }
                if r.alpha < 0.99 { fail(index, "rail alpha \(r.alpha) (\(r), header y \(Piece.f(h.minY)))") }
                if abs((r.minY - h.minY) - railOffset) > 0.5 {
                    fail(index, "rail y \(Piece.f(r.minY)), header y \(Piece.f(h.minY)): offset \(Piece.f(r.minY - h.minY)), was \(Piece.f(railOffset))")
                }
            }
            for id in members {
                guard let was = before.members[id], was.shown else { continue }
                let now = frame.members[id] ?? Piece()
                if now.object != was.object { fail(index, "member \(id.rawValue) view replaced or gone (\(now))") }
                if !now.shown { fail(index, "member \(id.rawValue) detached or hidden (\(now))") }
                if now.alpha < 0.99 { fail(index, "member \(id.rawValue) alpha \(now.alpha) (\(now))") }
            }
        }
        monotonic("header", frames.map(\.header.minY), start: before.header.minY, end: after.header.minY)
        if folds {
            // The lines shown after the fold are the ones a full pass makes.
            let shown = list.groupLineViews.lines.map { "\($0.group.rawValue) \($0.frame)" }
            let made = list.groupLines(list.displayed).map { "\($0.group.rawValue) \($0.frame)" }
            if shown != made { fail(frames.count, "lines after the fold \(shown), a full pass makes \(made)") }
            let lowerRail = piece(view: rail(list, lower), in: list, flipped: flipped)
            if !lowerRail.shown || lowerRail.alpha < 0.99 { fail(frames.count, "second group's rail after the fold: \(lowerRail)") }
        }
        if !folds, before.rail.shown, after.rail.shown { monotonic("rail top", frames.map(\.rail.minY), start: before.rail.minY, end: after.rail.minY) }
        for id in members {
            guard let was = before.members[id], was.shown, let end = after.members[id], end.shown else { continue }
            monotonic("member \(id.rawValue)", frames.map { $0.members[id]?.minY ?? .nan }, start: was.minY, end: end.minY)
        }

        let ys = frames.map(\.header.minY)
        let moved = Set(ys.map { Int(($0 * 2).rounded()) }).count
        log.append("\(label): applies \(applies), flipped \(flipped), header y \(Piece.f(before.header.minY)) -> \(Piece.f(after.header.minY)) over \(moved) distinct positions; "
            + "fill \(before.fill), rim \(before.rim), rail \(before.rail) -> \(after.rail); frame ys \(ys.prefix(8).map(Piece.f))")
        return failures
    }

    @Test func theTopGroupHoldsStillInEveryFrame() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let kinds = DesignSettings.shared.enabledAnimations
        defer { DesignSettings.shared.enabledAnimations = kinds }
        var log = ["animatesMovement \(Motion.sidebar.animatesMovement), screens \(NSScreen.screens.count)"]
        var failures: [String] = []
        // `ui.animations.newWorkspace` on: a new row opens its slot on the spring, so the rows around it move.
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        for event in Event.allCases { failures += Self.run(event, intent: true, log: &log).map { "[newWorkspace motion] " + $0 } }
        failures += Self.run(.insertAbove, intent: true, then: .memberGrows, log: &log).map { "[newWorkspace motion] " + $0 }
        failures += Self.run(.insertAbove, intent: true, then: .insertBelow, log: &log).map { "[newWorkspace motion] " + $0 }
        DesignSettings.shared.enabledAnimations = kinds
        for intent in [true, false] {
            failures += Self.run(.memberGrows, intent: intent, topCollapsed: true, log: &log)
            for event in Event.allCases { failures += Self.run(event, intent: intent, log: &log) }
            // A height change while the spring of the change before it still runs.
            failures += Self.run(.insertAbove, intent: intent, then: .memberGrows, log: &log)
            failures += Self.run(.memberGrows, intent: intent, then: .insertBelow, log: &log)
        }
        print("SidebarGroupFlicker log:\n" + log.joined(separator: "\n"))
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(60).joined(separator: "\n"))")
    }

    /// New Workspace in New Group: a group with members opens at the top, on the spring (then, `then`, another row
    /// opens above it two frames later, while that spring runs). In every frame from the first one its header shows,
    /// its rail draws at its header's opacity, and never past its last member's drawn bottom; the header view stays
    /// the same view once made, and its opacity never goes back down.
    static func runNewGroup(then: Bool, log: inout [String]) -> [String] {
        let (model, list, window) = make()
        defer { window.close() }
        let label = "g: a new group opens at the top\(then ? " + h: a row opens above it 2 frames later" : "") (user intent)"
        guard let anyHeader = list.rowViews[.group(top)], let anyLayer = anyHeader.layer else { return ["\(label): no header"] }
        let flipped = abs(anyLayer.frame.minY - anyHeader.frame.minY) > 0.5
        var frames: [(String, Frame)] = []
        list.onApply = { _ in frames.append(("apply \(frames.count)", sample(list, flipped: flipped, group: fresh, members: freshMembers))) }
        model.noteUserIntent()
        model.sections = [SidebarSection(kind: .machine(machine), nodes: nodes(newGroup: true))]
        model.activeWorkspaceID = freshMembers[0]
        model.selection = [freshMembers[0]]
        list.reload(animated: true, fromModel: true) // SidebarView's observation: a new selection with new rows
        list.layoutSubtreeIfNeeded()
        CATransaction.flush()
        frames.append(("frame 0", sample(list, flipped: flipped, group: fresh, members: freshMembers)))
        for index in 1...30 {
            if then, index == 2 {
                model.noteUserIntent()
                model.sections = [SidebarSection(kind: .machine(machine), nodes: nodes(above: [WorkspaceID("x")], newGroup: true))]
                list.showModelChange(animates: true)
            }
            step(list)
            frames.append(("frame \(index)", sample(list, flipped: flipped, group: fresh, members: freshMembers)))
        }
        var failures: [String] = []
        var header: ObjectIdentifier?
        var lastAlpha: Float = 0
        for (name, frame) in frames {
            func fail(_ what: String) { failures.append("\(label), \(name): \(what)") }
            let h = frame.header, r = frame.rail
            if let header, h.object != header { fail("new group's header view replaced or gone (\(h))") }
            if header == nil, h.object != nil { header = h.object }
            if header != nil, h.shown, h.alpha + 0.02 < lastAlpha { fail("header alpha went back \(lastAlpha) -> \(h.alpha)") }
            if h.shown { lastAlpha = max(lastAlpha, h.alpha) }
            if r.shown, h.shown, abs(r.alpha - h.alpha) > 0.05 { fail("rail alpha \(r.alpha), header alpha \(h.alpha) (rail \(r), header \(h))") }
            if r.shown, !h.shown, r.alpha > 0.05 { fail("rail drawn (\(r)) with no header shown (\(h))") }
            if r.shown, r.alpha > 0.05, let last = freshMembers.reversed().compactMap({ frame.members[$0] }).first(where: \.shown) {
                if r.maxY > last.maxY + 0.5 { fail("rail bottom \(Piece.f(r.maxY)) past its last member's bottom \(Piece.f(last.maxY)) (rail \(r), member \(last))") }
            } else if r.shown, r.alpha > 0.05 {
                fail("rail drawn (\(r)) with no member row shown")
            }
        }
        if let end = frames.last?.1, !(end.header.shown && end.header.alpha > 0.99 && end.rail.shown && end.rail.alpha > 0.99) {
            failures.append("\(label), end: header \(end.header), rail \(end.rail)")
        }
        log.append("\(label): \(frames.map { "\($0.0): h \($0.1.header) r \($0.1.rail)" }.prefix(6).joined(separator: "; "))")
        return failures
    }

    @Test func aNewGroupAndItsRailOpenAsOne() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let kinds = DesignSettings.shared.enabledAnimations
        defer { DesignSettings.shared.enabledAnimations = kinds }
        var log: [String] = []
        var failures = Self.runNewGroup(then: false, log: &log) + Self.runNewGroup(then: true, log: &log)
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        failures += (Self.runNewGroup(then: false, log: &log) + Self.runNewGroup(then: true, log: &log)).map { "[newWorkspace motion] " + $0 }
        print("SidebarGroupFlicker new group log:\n" + log.joined(separator: "\n"))
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(60).joined(separator: "\n"))")
    }
}
