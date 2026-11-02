import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-10-21: "right now adding a workspace at the top ... it pushes all the stuff down". The rows
/// below an insert make room on the render server's spring (`RowMotion.animate`, `SidebarDragSpring`): each
/// row's frame is at its slot at once and an additive spring carries what is on screen there, so the main
/// thread writes no row frame per display frame. AppKit's spring wrote every moving row's frame each frame.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowsMoveOnRenderServerTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func ws(_ id: String) -> CmuxNextSidebar.SidebarWorkspace { CmuxNextSidebar.SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID(id), title: id) }

    /// The ungrouped workspaces `top`, then group Work (open, its `members`, so it draws its line).
    private static func grouped(_ top: [String], members: [String] = ["docs", "web", "api"]) -> [CmuxNextSidebar.SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let work = CmuxNextSidebar.SidebarGroup(id: GroupID("g-work"), name: "Work", color: .blue, workspaces: members.map(ws))
        return [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: top.map { .workspace(ws($0)) } + [.group(work)])]
    }

    /// The render server's additive springs of `keyPath` on `view`'s layer (`SidebarDragSpring`). AppKit's spring
    /// runs on the main thread and adds none.
    private static func springs(_ view: NSView, _ keyPath: String) -> Int {
        guard let layer = view.layer else { return 0 }
        return (layer.animationKeys() ?? []).filter { key in
            (layer.animation(forKey: key) as? CASpringAnimation).map { $0.isAdditive && $0.keyPath == keyPath } ?? false
        }.count
    }

    private static func positionSprings(_ view: NSView) -> Int { springs(view, "position") }

    private static func sizeSprings(_ view: NSView) -> Int { springs(view, "bounds.size") }

    @Test
    func recyclingAParkedRowStopsItsListSpring() {
        let list = SidebarListView(model: SidebarModel())
        let view = SidebarRowView(key: .workspace(WorkspaceID("recycled")))
        list.addSubview(view)
        let spring = CASpringAnimation(keyPath: "position")
        spring.isAdditive = true
        view.layer?.add(spring, forKey: "\(SidebarDragSpring.batchKey).position.test")

        #expect(Self.positionSprings(view) == 1)
        list.recycle(view)
        #expect(Self.positionSprings(view) == 0)
    }

    @Test
    func anOldCloseCannotFinishTheReusedRowsNewClose() throws {
        let list = SidebarListView(model: SidebarModel())
        let key = SidebarRowKey.workspace(WorkspaceID("reused"))
        let view = list.dequeue(key)
        list.addSubview(view)
        let oldClose = view.reuseGeneration
        list.recycle(view)
        let reused = list.dequeue(key)
        try #require(reused === view)
        // It left rowViews for a second close before the first close's completion arrived.
        reused.closingEnd = .zero
        list.fadingRows[ObjectIdentifier(reused)] = reused
        let spring = CASpringAnimation(keyPath: "position")
        spring.isAdditive = true
        reused.layer?.add(spring, forKey: "\(SidebarDragSpring.batchKey).position.test")
        list.finishLeaving(view, generation: oldClose)
        #expect(!reused.isHidden)
        #expect(Self.positionSprings(reused) == 1)
        #expect(list.fadingRows[ObjectIdentifier(reused)] === reused)
        list.finishLeaving(reused, generation: reused.reuseGeneration)
        #expect(reused.isHidden && reused.closingEnd == nil)
        #expect(Self.positionSprings(reused) == 0)
        #expect(list.fadingRows.isEmpty)
    }

    /// The rows and group lines that still carry a row move's spring.
    private static func springing(_ list: SidebarListView) -> [String] {
        list.subviews.filter { $0 is SidebarRowView || $0 is GroupLineView }.compactMap { view in
            positionSprings(view) + sizeSprings(view) > 0 ? ((view as? SidebarRowView).map { "\($0.key)" } ?? "a group line") : nil
        }
    }

    /// Each shown row and group line not at its layout frame or not opaque.
    private static func offSlot(_ list: SidebarListView) -> [String] {
        var off = list.rowViews.compactMap { key, view -> String? in
            guard let row = list.displayed.row(for: key) else { return "\(key) has no row" }
            return view.frame == list.frame(for: row) && view.alphaValue == 1 ? nil : "\(key) at \(view.frame) alpha \(view.alphaValue)"
        }
        let lines = SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }
        for line in lines where list.groupLineViews.shown[line.group].map({ $0.frame != line.frame || $0.alpha != 1 }) ?? true {
            off.append("line \(line.group.rawValue)")
        }
        return off
    }

    /// Workspaces 1 to `count` in a window on screen (`sidebar(_:)`).
    private static func sidebar(count: Int) throws -> (SidebarModel, SidebarListView, NSWindow, restore: () -> Void) {
        try sidebar(sections(Array(1...count)))
    }

    /// `start` in a window on screen, its first workspace selected, the list at its top, with new
    /// workspace rows opening (`ui.animations.newWorkspace`, off by default) and Reduce Motion off.
    private static func sidebar(_ start: [CmuxNextSidebar.SidebarSection]) throws -> (SidebarModel, SidebarListView, NSWindow, restore: () -> Void) {
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        if window.screen == nil { window.close() } // the require below throws before any test's restore
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let kinds = DesignSettings.shared.enabledAnimations
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, window, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            DesignSettings.shared.animationSpeed = speed
            window.close()
        })
    }

    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func anInsertAtTheTopMovesTheRowsBelowOnTheRenderServer() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        model.noteUserIntent()
        let clip = try #require(list.enclosingScrollView?.contentView)
        let shown = list.rowViews.compactMap { key, view -> (SidebarRowKey, SidebarRowView, CGFloat)? in
            if case .workspace = key { (key, view, view.frame.minY - clip.bounds.minY) } else { nil }
        }

        // The new row goes right under the first one, which stays in place. An insert above the first shown row keeps
        // what the user sees still (`ListViewport.anchored`, close-focus.md V5): the list scrolls by the new row's height
        // and no row moves on screen (the run read "pushed 0 rows down"). In the app Home stands above the list, so a new
        // row at the list's top lands under a row that holds still, as here.
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)

        // The rows the insert pushed down on screen: every shown row under the first one.
        var moved = 0
        for (key, view, wasOnScreen) in shown {
            let row = try #require(list.displayed.row(for: key))
            let slot = list.frame(for: row)
            guard abs(slot.minY - clip.bounds.minY - wasOnScreen) > 0.5 else { continue }
            moved += 1
            // The model frame is at the slot now: nothing moves it on the main thread later.
            #expect(view.frame == slot, "\(key) is at \(view.frame), its slot is \(slot)")
            #expect(Self.positionSprings(view) >= 1, "\(key) did not move on the render server")
        }
        #expect(moved > 3, "the insert near the top pushed \(moved) rows down (of \(shown.count) shown)")
        let firstKey = SidebarRowKey.workspace(try #require(Self.sections([1]).first?.workspaces.first?.id))
        let first = try #require(shown.first { $0.0 == firstKey }, "the first row is not shown")
        #expect(abs(first.1.frame.minY - clip.bounds.minY - first.2) <= 0.5, "the first row moved: the insert is not under a still row")
        let added = try #require(Self.sections([0]).first?.workspaces.first?.id)
        let opening = try #require(list.rowViews[.workspace(added)], "the new row near the top has no view")
        let slot = try #require(list.displayed.row(for: opening.key).map(list.frame(for:)))
        #expect(opening.frame == slot, "the new row is at \(opening.frame), its slot is \(slot)")
        #expect(Self.sizeSprings(opening) >= 1, "the new row did not open its slot on the render server")
        #expect(opening.alphaValue < 1, "the new row showed whole in one frame")
    }

    /// Leo 2026-10-21: "when you create a workspace at the top it's a huge cascade".
    /// The nudge variant: each row below a new row near the top travels at most the nudge, not a row height, and the
    /// new row opens only its last nudge of height, on a spring that is at rest by 150 ms (`SidebarInsertMotionTests`).
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNewRowNearTheTopNudgesTheRowsBelowByAtMostTheNudge() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.nudge)
        defer { reset() }
        try #require(SidebarInsertMotion.tunable.value == .nudge)
        let nudge = SidebarInsertMotion.nudgeDistance.value

        // Cmd-N: the user's own request, so its change moves rows (a change nobody asked for shows in one step,
        // `SidebarListView.showModelChange`). The new row goes below the first one, which stays in place: an insert
        // above the first shown row keeps what the user sees still (`ListViewport.anchored`), so no row would move.
        // In the app Home stands above the list and is that row.
        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)

        var springs = 0
        for view in list.rowViews.values {
            guard let layer = view.layer else { continue }
            for key in layer.animationKeys() ?? [] {
                guard let spring = layer.animation(forKey: key) as? CASpringAnimation, spring.isAdditive,
                      let from = spring.fromValue as? NSValue else { continue }
                springs += 1
                let travel = spring.keyPath == "position" ? max(abs(from.pointValue.x), abs(from.pointValue.y))
                    : max(abs(from.sizeValue.width), abs(from.sizeValue.height))
                #expect(travel <= nudge + 0.01, "\(view.key) \(spring.keyPath ?? "") travels \(travel) pt")
                #expect(spring.duration < 0.15, "\(view.key) moves for \(spring.duration) s")
            }
        }
        #expect(springs > 3, "the insert at the top moved \(springs) springs")
    }

    @Test(.enabled("needs an awake display and animations on") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func defaultInsertPlacesExistingRowsWithoutSprings() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(SidebarInsertMotion.tunable.defaultValue)
        defer { reset() }
        let oldViews = list.rowViews
        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        for (key, view) in oldViews where list.rowViews[key] === view {
            let row = try #require(list.displayed.row(for: key))
            #expect(view.frame == list.frame(for: row))
            #expect(Self.positionSprings(view) + Self.sizeSprings(view) == 0)
        }
        #expect(list.openingRows.isEmpty)
    }

    /// Where `view` is drawn at media time `time`, in its superlayer's coordinates: its model geometry plus every
    /// additive spring on its layer now, run forward to `time` (`MotionPath.springProgress`, Core Animation's spring).
    private static func drawn(_ view: NSView, at time: CFTimeInterval) -> CGRect? {
        guard let layer = view.layer else { return nil }
        var position = layer.position, size = layer.bounds.size
        let local = layer.convertTime(time, from: nil)
        for key in layer.animationKeys() ?? [] {
            guard let spring = layer.animation(forKey: key) as? CASpringAnimation, spring.isAdditive,
                  let from = spring.fromValue as? NSValue else { continue }
            let left = 1 - MotionPath.springProgress(spring, at: local - spring.beginTime)
            if spring.keyPath == "position" {
                position.x += from.pointValue.x * left
                position.y += from.pointValue.y * left
            } else if spring.keyPath == "bounds.size" {
                size.width += from.sizeValue.width * left
                size.height += from.sizeValue.height * left
            }
        }
        let anchor = layer.anchorPoint
        return CGRect(x: position.x - anchor.x * size.width, y: position.y - anchor.y * size.height, width: size.width, height: size.height)
    }

    /// Codex review of #24374: a second new row 30 ms after the first stacked a second nudge on the rows still
    /// moving from the first, so a row travelled 12 pt, or jumped, or overlapped the new row. Every frame for
    /// 300 ms after the second insert: no workspace row is drawn more than the nudge from its slot, and none
    /// overlaps the next one.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func twoQuickNewRowsNeverMoveARowPastTheNudgeOrOverlap() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.nudge)
        defer { reset() }
        try #require(SidebarInsertMotion.tunable.value == .nudge)
        let nudge = SidebarInsertMotion.nudgeDistance.value

        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        model.noteUserIntent()
        model.sections = Self.sections([1, 999, 0] + Array(2...30))
        list.reload(animated: true)
        let now = CACurrentMediaTime()

        let rows = list.rowViews.compactMap { key, view -> (SidebarRowKey, SidebarRowView)? in
            if case .workspace = key, view.layer != nil { (key, view) } else { nil }
        }.sorted { ($0.1.layer?.frame.minY ?? 0) < ($1.1.layer?.frame.minY ?? 0) }
        try #require(rows.count > 5)
        var worst: CGFloat = 0
        var springs = 0
        for (_, view) in rows { springs += Self.positionSprings(view) + Self.sizeSprings(view) }
        #expect(springs > 3, "the second insert moved \(springs) springs")
        for step in 0...72 {
            let time = now + Double(step) / 240
            let frames = rows.map { (key: $0.0, slot: $0.1.layer?.frame ?? .zero, drawn: Self.drawn($0.1, at: time) ?? .zero) }
            for row in frames {
                let off = max(abs(row.drawn.minY - row.slot.minY), abs(row.drawn.maxY - row.slot.maxY))
                worst = max(worst, off)
                #expect(off <= nudge + 0.5, "\(row.key) is drawn \(off) pt from its slot \(step * 1000 / 240) ms on")
            }
            for (above, below) in zip(frames, frames.dropFirst()) {
                #expect(above.drawn.maxY <= below.drawn.minY + 0.5,
                        "\(above.key) overlaps \(below.key) by \(above.drawn.maxY - below.drawn.minY) pt \(step * 1000 / 240) ms on")
            }
        }
        #expect(worst > 0, "no row moved at all")
    }

    /// Codex review of #24374: a group's expand lists its members again, which are no new workspaces. They come out
    /// from under the header on `.move` over their whole distance, as on base, not on the new row nudge.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func expandingAGroupMovesAsBeforeNotByTheNudge() throws {
        func work(collapsed: Bool) -> [CmuxNextSidebar.SidebarSection] {
            var sections = Self.grouped(["w1", "w2"])
            guard case var .group(group) = sections[0].nodes[2] else { return sections }
            group.isCollapsed = collapsed
            sections[0].nodes[2] = .group(group)
            return sections
        }
        let (model, list, _, restore) = try Self.sidebar(work(collapsed: true))
        defer { restore() }
        let reset = Self.insertMotion(.nudge)
        defer { reset() }
        try #require(SidebarInsertMotion.tunable.value == .nudge)
        let nudge = SidebarInsertMotion.nudgeDistance.value
        try #require(list.rowViews[.workspace(CmuxNextSidebar.WorkspaceID("api"))] == nil, "the group did not start collapsed")

        model.noteUserIntent()
        model.sections = work(collapsed: false)
        list.reload(animated: true)

        let moveDuration = Motion.sidebar.springAnimation(.move, "position", from: 0, to: 0).duration
        var farthest: CGFloat = 0
        for member in ["docs", "web", "api"] {
            let view = try #require(list.rowViews[.workspace(CmuxNextSidebar.WorkspaceID(member))], "\(member) has no view")
            for key in view.layer?.animationKeys() ?? [] {
                guard let spring = view.layer?.animation(forKey: key) as? CASpringAnimation, spring.isAdditive,
                      spring.keyPath == "position", let from = spring.fromValue as? NSValue else { continue }
                farthest = max(farthest, abs(from.pointValue.y))
                #expect(abs(spring.duration - moveDuration) < 0.001, "\(member) moves for \(spring.duration) s, .move is \(moveDuration) s")
            }
        }
        #expect(farthest > nudge + 1, "the expanded members came out by at most \(farthest) pt (the nudge), not from under the header")
    }

    /// Codex review of #24374: a row's open is over once the spring it opened on settles. Under the nudge that is
    /// `.tabOpen`, shorter than `.move`: a reorder just after it moves the row, in the same view, and does not open
    /// it again (a new view, its fade and its size replayed).
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNewRowWhoseOpenSettledMovesWithoutOpeningAgain() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.nudge)
        defer { reset() }
        try #require(SidebarInsertMotion.tunable.value == .nudge)
        let key = SidebarRowKey.workspace(try #require(Self.sections([0]).first?.workspaces.first?.id))

        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        // The reload reads the media time once, somewhere between these two reads; on a loaded runner the reload
        // itself took 38 ms (run 41358792657), so a fixed 20 ms window around the read after it measured the host.
        let beforeReload = CACurrentMediaTime()
        list.reload(animated: true)
        let afterReload = CACurrentMediaTime()
        let view = try #require(list.rowViews[key])
        let until = try #require(list.openingRows[key]?.until)
        let open = Motion.sidebar.spring(SidebarInsertMotion.nudge.token).settlingTime()
        #expect(until >= beforeReload + open - 0.001 && until <= afterReload + open + 0.001,
                "the open ends \(until - beforeReload) s after the reload began (\(afterReload - beforeReload) s long), its spring settles in \(open) s")
        #expect(open < Motion.sidebar.spring(.move).settlingTime())

        RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0, until - CACurrentMediaTime()) + 0.01))
        let sizing = Self.sizeSprings(view)
        model.noteUserIntent()
        model.sections = Self.sections([1, 2, 0] + Array(3...30))
        list.reload(animated: true)

        #expect(list.rowViews[key] === view, "the settled row opened again in a new view")
        #expect(Self.sizeSprings(view) <= sizing, "the settled row opened its slot again")
    }

    /// Sets the new row motion and its nudge for one test (`SidebarInsertMotion`); the returned closure resets both.
    private static func insertMotion(_ motion: SidebarInsertMotion, nudge: CGFloat? = nil) -> () -> Void {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(motion.rawValue))
        if let nudge { TunableStore.shared.set(SidebarInsertMotion.nudgeDistance.key, .number(Double(nudge))) }
        return {
            TunableStore.shared.set(SidebarInsertMotion.tunable.key, nil)
            TunableStore.shared.set(SidebarInsertMotion.nudgeDistance.key, nil)
        }
    }

    /// The shown workspace rows, top to bottom, each with its slot and where it is drawn at media time `time`.
    private static func drawnRows(_ list: SidebarListView, at time: CFTimeInterval) -> [(key: SidebarRowKey, slot: CGRect, drawn: CGRect)] {
        list.rowViews.compactMap { key, view -> (key: SidebarRowKey, slot: CGRect, drawn: CGRect)? in
            guard case .workspace = key, let layer = view.layer, let drawn = drawn(view, at: time) else { return nil }
            return (key, layer.frame, drawn)
        }.sorted { $0.slot.minY < $1.slot.minY }
    }

    /// Codex review of #24374 at 618df18: a nudge set past the new row's height (40 pt over a 28 pt row) started a row
    /// below that an earlier insert still moved 40 pt up, above the new row's top, so it crossed the new row as it
    /// opened. The travel now stops at the new rows' height. Two inserts 30 ms apart, the second below rows the first
    /// still moves: in no frame for 300 ms does a workspace row overlap the next one.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNudgePastTheRowHeightNeverCrossesTheNewRow() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.nudge, nudge: 40)
        defer { reset() }
        try #require(SidebarInsertMotion.nudgeDistance.value == 40)

        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        model.noteUserIntent()
        model.sections = Self.sections([1, 0, 2, 999] + Array(3...30))
        list.reload(animated: true)
        let now = CACurrentMediaTime()

        try #require(Self.drawnRows(list, at: now).count > 5)
        for step in 0...72 {
            let rows = Self.drawnRows(list, at: now + Double(step) / 240)
            for (above, below) in zip(rows, rows.dropFirst()) {
                #expect(above.drawn.maxY <= below.drawn.minY + 0.5,
                        "\(below.key) is drawn \(above.drawn.maxY - below.drawn.minY) pt over \(above.key) \(step * 1000 / 240) ms on")
            }
        }
    }

    /// The same nudge past the row's height on one insert: the rows below and the new row move as one, so no gap opens
    /// between any two workspace rows (each pair stays as far apart as their slots) and none overlaps, in every frame.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNudgePastTheRowHeightOpensWithNoGapAndNoOverlap() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.nudge, nudge: 40)
        defer { reset() }
        try #require(SidebarInsertMotion.nudgeDistance.value == 40)

        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        let now = CACurrentMediaTime()

        try #require(Self.drawnRows(list, at: now).count > 5)
        for step in 0...72 {
            let rows = Self.drawnRows(list, at: now + Double(step) / 240)
            for (above, below) in zip(rows, rows.dropFirst()) {
                let gap = below.drawn.minY - above.drawn.maxY, slotGap = below.slot.minY - above.slot.maxY
                #expect(abs(gap - slotGap) <= 0.5, "\(above.key) and \(below.key) are \(gap) pt apart (slots \(slotGap)) \(step * 1000 / 240) ms on")
            }
        }
    }

    /// Codex review of #24374 at 618df18: a new row an insert made outside the realized rows opened, once a scroll
    /// brought it in, from zero height on `.move` whatever the new row motion. Snap and a zero nudge open nothing (the
    /// row shows at its slot), and quick opens on its own spring.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNewRowAScrollBringsInOpensByTheChosenMotion() throws {
        for (motion, nudge) in [(SidebarInsertMotion.snap, nil), (.nudge, CGFloat(0)), (.quick, nil)] as [(SidebarInsertMotion, CGFloat?)] {
            let (model, list, _, restore) = try Self.sidebar(count: 60)
            defer { restore() }
            let reset = Self.insertMotion(motion, nudge: nudge)
            defer { reset() }
            let key = SidebarRowKey.workspace(try #require(Self.sections([0]).first?.workspaces.first?.id))

            model.noteUserIntent()
            model.sections = Self.sections(Array(1...54) + [0] + Array(55...60))
            list.reload(animated: true)
            try #require(list.rowViews[key] == nil, "\(motion): the new row was realized at the insert")
            let opening = list.openingRows[key]
            let slot = try #require(list.displayed.row(for: key).map(list.frame(for:)))
            let clip = try #require(list.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: max(0, slot.minY - 100)))
            list.enclosingScrollView?.reflectScrolledClipView(clip)
            list.realizeVisibleRows()
            let view = try #require(list.rowViews[key], "\(motion): the scroll did not realize the new row")

            if motion == .quick {
                #expect(opening?.motion == .quick, "\(motion): the row is not opening by the quick motion")
                let quick = Motion.sidebar.springAnimation(.tabOpen, "bounds.size", from: 0, to: 0).duration
                let springs = (view.layer?.animationKeys() ?? []).compactMap { view.layer?.animation(forKey: $0) as? CASpringAnimation }
                    .filter { $0.isAdditive && $0.keyPath == "bounds.size" }
                #expect(!springs.isEmpty, "\(motion): the row showed whole instead of opening")
                for spring in springs {
                    #expect(abs(spring.duration - quick) < 0.001, "\(motion): the row opens for \(spring.duration) s, .tabOpen is \(quick) s")
                    #expect(abs(((spring.fromValue as? NSValue)?.sizeValue.height ?? 0) + slot.height) < 0.5, "\(motion): not from zero height")
                }
            } else {
                #expect(opening == nil, "\(motion) nudge \(nudge ?? -1): the row was marked as opening")
                #expect(view.frame == slot && view.alphaValue == 1, "\(motion): the row is at \(view.frame) alpha \(view.alphaValue), slot \(slot)")
                #expect(Self.sizeSprings(view) + Self.positionSprings(view) == 0, "\(motion): the row moved")
            }
        }
    }

    /// Codex review of #24374 at 2c21552: one change that adds a workspace and closes another gave the closing row the
    /// insert's cap and spring (under snap it vanished at once, under the nudge it closed from a shortened row). A change
    /// that does more than add rows moves every row as before: the closing row closes its whole height on `.move`.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aRowClosedInTheSameChangeAsAnInsertClosesAsBefore() throws {
        for motion in [SidebarInsertMotion.nudge, .snap, .quick] {
            let (model, list, _, restore) = try Self.sidebar(count: 30)
            defer { restore() }
            let reset = Self.insertMotion(motion)
            defer { reset() }
            let closedKey = SidebarRowKey.workspace(try #require(Self.sections([3]).first?.workspaces.first?.id))
            let closing = try #require(list.rowViews[closedKey])
            let height = closing.frame.height

            model.noteUserIntent()
            model.sections = Self.sections([1, 0, 2] + Array(4...30))
            list.reload(animated: true)

            #expect(closing.superview != nil && closing.closingEnd != nil, "\(motion): the closed row went at once instead of closing")
            let move = Motion.sidebar.springAnimation(.move, "bounds.size", from: 0, to: 0).duration
            let sizes = (closing.layer?.animationKeys() ?? []).compactMap { closing.layer?.animation(forKey: $0) as? CASpringAnimation }
                .filter { $0.isAdditive && $0.keyPath == "bounds.size" }
            #expect(sizes.count == 1, "\(motion): the closed row has \(sizes.count) size springs")
            for spring in sizes {
                #expect(abs(((spring.fromValue as? NSValue)?.sizeValue.height ?? 0) - height) < 0.5,
                        "\(motion): the closed row closes \((spring.fromValue as? NSValue)?.sizeValue.height ?? 0) pt of its \(height)")
                #expect(abs(spring.duration - move) < 0.001, "\(motion): the closed row closes in \(spring.duration) s, .move is \(move) s")
            }
        }
    }

    /// Codex review of #24374 at 2c21552: rows placed without motion (the display's sleep settling a move, a reload
    /// without motion, Reduce Motion) left an offscreen new row's open armed, so a scroll to it before the open's
    /// deadline replayed the open. Each path settles every open (`settleOpenings`): the row shows at its slot.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNewRowPlacedWithoutMotionShowsAtItsSlotWhenScrolledTo() throws {
        for path in ["display sleep", "reload without motion", "Reduce Motion"] {
            // The scroll must come inside the open's wall-clock window (the `.move` spring, under a second). A loaded
            // runner missed it by 6 ms (run 41358792657, Reduce Motion), so a late attempt runs again on a new sidebar.
            var inTime = false
            for _ in 0..<3 where !inTime { inTime = try Self.placeWithoutMotionThenScroll(path) }
            #expect(inTime, "\(path): in 3 tries the scroll never came before the open would have ended anyway")
        }
    }

    /// One try of `aNewRowPlacedWithoutMotionShowsAtItsSlotWhenScrolledTo` by `path`: false when the scroll came after
    /// the open's deadline, so the try showed nothing.
    private static func placeWithoutMotionThenScroll(_ path: String) throws -> Bool {
        let (model, list, _, restore) = try Self.sidebar(count: 60)
        defer { restore() }
        // The full spring at normal speed: the longest open, so the scroll below comes well inside it.
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        DesignSettings.shared.animationSpeed = .normal
        let key = SidebarRowKey.workspace(try #require(Self.sections([0]).first?.workspaces.first?.id))
        let opensUntil = CACurrentMediaTime() + Motion.sidebar.spring(.move).settlingTime()

        if path == "Reduce Motion" { Motion.reduceMotionOverride = true }
        // A new row in view (it moves the rows below it) and one far below the realized rows.
        model.noteUserIntent()
        model.sections = Self.sections([1, 500] + Array(2...54) + [0] + Array(55...60))
        list.reload(animated: true)
        try #require(list.rowViews[key] == nil, "\(path): the new row was realized at the insert")
        switch path {
        case "display sleep":
            try #require(list.openingRows[key] != nil, "\(path): the insert did not open the new row")
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
            workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
        case "reload without motion":
            try #require(list.openingRows[key] != nil, "\(path): the insert did not open the new row")
            list.reload(animated: false)
        default:
            Motion.reduceMotionOverride = false
        }
        #expect(list.openingRows[key] == nil, "\(path): the new row is still opening")

        let slot = try #require(list.displayed.row(for: key).map(list.frame(for:)))
        let clip = try #require(list.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: max(0, slot.minY - 100)))
        list.enclosingScrollView?.reflectScrolledClipView(clip)
        list.realizeVisibleRows()
        // Only a scroll before the open's deadline can replay it; a later one proves nothing, so the caller tries again.
        guard CACurrentMediaTime() < opensUntil else { return false }
        let view = try #require(list.rowViews[key], "\(path): the scroll did not realize the new row")
        #expect(view.frame == slot && view.alphaValue == 1, "\(path): the row is at \(view.frame) alpha \(view.alphaValue), slot \(slot)")
        #expect(Self.sizeSprings(view) + Self.positionSprings(view) == 0, "\(path): the row opened again")
        return true
    }

    /// A second insert while the first one's rows still move: each row keeps the first spring and adds one
    /// from where it is now, so nothing on screen jumps back to the first move's end. Under the full spring
    /// (`sidebar.insertMotion` spring); the nudge instead caps what is drawn (`twoQuickNewRowsNeverMoveARowPastTheNudgeOrOverlap`).
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aSecondInsertStacksOnTheFirstMove() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        try #require(SidebarInsertMotion.tunable.value == .spring)
        // Both inserts go under the first row, which holds still (as `anInsertAtTheTopMovesTheRowsBelowOnTheRenderServer`):
        // above it, the list keeps what the user sees still and no row moves. Workspace 2 is pushed by both.
        let key = SidebarRowKey.workspace(try #require(Self.sections([2]).first?.workspaces.first?.id))
        let view = try #require(list.rowViews[key])

        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        try #require(Self.positionSprings(view) == 1)
        model.sections = Self.sections([1, 999, 0] + Array(2...30))
        list.reload(animated: true)

        #expect(list.rowViews[key] === view)
        #expect(Self.positionSprings(view) == 2, "the second move replaced the first one's spring (a jump)")
        let row = try #require(list.displayed.row(for: key))
        #expect(view.frame == list.frame(for: row))
    }

    /// The display goes to sleep mid-move: the rows drop their springs and stand at their slots.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aMoveTheDisplaySleepsThroughEndsAtTheSlots() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        model.noteUserIntent()
        // Under the first row, so the rows below move (above it, the list holds what the user sees still).
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        try #require(list.rowViews.values.contains { Self.positionSprings($0) > 0 })

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        for (key, view) in list.rowViews {
            #expect(Self.positionSprings(view) == 0 && Self.sizeSprings(view) == 0, "\(key) still springs with the display asleep")
            let row = try #require(list.displayed.row(for: key))
            #expect(view.frame == list.frame(for: row) && view.alphaValue == 1, "\(key) did not end at its slot")
        }
    }

    /// Codex review of #24187: a change without motion mid-move (a reload without animation) put the frames at
    /// their slots but left the springs on, so the rows kept drawing the old move's offsets over them.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aReloadWithoutMotionMidMoveShowsTheSlotsAtOnce() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.grouped((1...8).map { "w\($0)" }))
        defer { restore() }
        // Remove a realized row while the insert starts its move: it stays as a closing subview with
        // its render-server spring until the animated move ends.
        model.sections = Self.grouped(["new"] + (1...7).map { "w\($0)" })
        list.reload(animated: true)
        try #require(!Self.springing(list).isEmpty, "the insert did not move on the render server")

        // Reintroduce that same key before the close ends. A calm reload must recycle the old leaving
        // view first, so the replacement is at its slot with no stale close spring attached.
        model.sections = Self.grouped(["new"] + (1...8).map { "w\($0)" })
        list.reload(animated: false)

        #expect(Self.springing(list).isEmpty, "still springing after a reload without motion: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at their slots: \(Self.offSlot(list))")
        #expect(list.rowViews.values.allSatisfy { $0.closingEnd == nil }, "a returned row still belongs to its earlier close")
    }

    /// Reduce Motion takes RowMotion's snap branch while `reload(animated:)` still reports an animated apply.
    /// The leaving row must be recycled before the same key is realized again in that effective snap path.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func reduceMotionReloadRecyclesAClosingRowBeforeReusingItsKey() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.grouped((1...8).map { "w\($0)" }))
        defer { restore() }
        model.sections = Self.grouped(["new"] + (1...7).map { "w\($0)" })
        list.reload(animated: true)
        try #require(!Self.springing(list).isEmpty, "the first change did not start a row move")

        Motion.reduceMotionOverride = true
        // Keep the removed workspace absent so `animate` remains true; this exercises the
        // effective snap gate (`!Motion.sidebar.animatesMovement`) rather than its `!animate` arm.
        model.sections = Self.grouped(["new"] + (1...7).reversed().map { "w\($0)" })
        list.reload(animated: true)

        #expect(Self.springing(list).isEmpty, "still springing after Reduce Motion snap: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at slots after Reduce Motion snap: \(Self.offSlot(list))")
        #expect(list.rowViews.values.allSatisfy { $0.closingEnd == nil }, "a returned row still belongs to its earlier close")
    }

    /// Reduce Motion turned on mid-move: the next change snaps, the earlier move's springs with it.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func reduceMotionMidMoveShowsTheSlotsAtOnce() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.grouped((1...8).map { "w\($0)" }))
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        model.noteUserIntent()
        model.sections = Self.grouped(["new"] + (1...8).map { "w\($0)" })
        list.reload(animated: true)
        try #require(!Self.springing(list).isEmpty, "the insert did not move on the render server")

        Motion.reduceMotionOverride = true
        model.sections = Self.grouped(["new", "newer"] + (1...8).map { "w\($0)" })
        list.reload(animated: true)

        #expect(Self.springing(list).isEmpty, "still springing under Reduce Motion: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at their slots: \(Self.offSlot(list))")
    }

    /// Codex review of #24187: a reorder of opaque rows fades nothing, so AppKit's leg ended at once and the
    /// display's sleep no longer reached the move: its springs stayed on. The springs' own leg keeps it tracked.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aReorderTheDisplaySleepsThroughEndsAtTheSlots() async throws {
        let (model, list, _, restore) = try Self.sidebar(count: 12)
        defer { restore() }
        // The slower pace keeps the move running past the turns AppKit takes to end its empty group.
        DesignSettings.shared.animationSpeed = .normal
        model.sections = Self.sections([5, 1, 2, 3, 4] + Array(6...12))
        list.reload(animated: true)
        #expect(list.rowViews.values.allSatisfy { $0.alphaValue == 1 }, "a row fades: the reorder is not the case under test")
        try await Task.sleep(for: .milliseconds(30))
        try #require(!Self.springing(list).isEmpty, "the reorder ended before the display slept")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        #expect(Self.springing(list).isEmpty, "still springing with the display asleep: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at their slots: \(Self.offSlot(list))")
    }

    /// Codex review of #24187: the display slept while an insert moved a group's line; the rows settled but the
    /// line kept its spring.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aGroupLineTheDisplaySleepsThroughEndsAtItsRows() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.grouped(["w1", "w2"]))
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        model.sections = Self.grouped(["new", "w1", "w2"])
        list.reload(animated: true)
        let lines = list.subviews.compactMap { $0 as? GroupLineView }
        try #require(lines.contains { Self.positionSprings($0) > 0 }, "the group's line did not move with its rows")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        #expect(Self.springing(list).isEmpty, "still springing with the display asleep: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at their slots: \(Self.offSlot(list))")
    }

    /// Codex review of #24187 (a4789e79): a member added past the realized rows of a long open group moved only the
    /// group's line. Its spring ran outside the rows' tracked transaction, which held nothing and ended at once,
    /// with AppKit's empty leg, so the display's sleep no longer reached the line.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aLineThatAloneMovesStillEndsWhenTheDisplaySleeps() async throws {
        let members = (1...60).map { "m\($0)" }
        let (model, list, _, restore) = try Self.sidebar(Self.grouped(["w1"], members: members))
        defer { restore() }
        let reset = Self.insertMotion(.spring)
        defer { reset() }
        DesignSettings.shared.animationSpeed = .normal
        model.sections = Self.grouped(["w1"], members: members + ["m61"])
        list.reload(animated: true)
        #expect(list.rowViews.values.allSatisfy { Self.positionSprings($0) + Self.sizeSprings($0) == 0 },
                "a realized row moved: the case under test is a line moving alone")
        // Past the turns both empty legs take to end.
        try await Task.sleep(for: .milliseconds(30))
        let lines = list.subviews.compactMap { $0 as? GroupLineView }
        try #require(lines.contains { Self.sizeSprings($0) + Self.positionSprings($0) > 0 }, "the group's line did not move")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        #expect(Self.springing(list).isEmpty, "still springing with the display asleep: \(Self.springing(list))")
    }

    /// Codex review of #24187 (a4789e79): with movement off, a history block already at its slot (an earlier move set
    /// its model frame) kept that move's spring: `place` handed on only the blocks whose frame changed.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aHistoryBlockAtItsSlotLosesItsSpringWhenMovementGoesOff() throws {
        let (_, list, _, restore) = try Self.sidebar(count: 3)
        defer { restore() }
        let state = SidebarChatHistoryState(pinned: [SidebarHistoryChat(id: "c1", title: "chat 1", updatedAt: Date(timeIntervalSince1970: 0))])
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState()
        options.chatHistory = state
        let layout = SidebarLayout.make(sections: Self.sections([1, 2, 3]), metrics: .standard, options: options)
        try #require(layout.pinnedChatsY != nil)
        let history = SidebarChatHistoryViews()
        history.place(layout, state: state, metrics: .standard, in: list, animated: false)
        let block = history.pinned
        let slot = block.frame
        // An earlier move: the block's model frame is at its slot, a spring still carries it there.
        Motion.withoutAnimation { block.frame = slot.offsetBy(dx: 0, dy: 40) }
        SidebarDragSpring.move([(block as NSView, slot)], in: list)
        try #require(Self.positionSprings(block) > 0, "the block did not move on the render server")

        Motion.reduceMotionOverride = true
        SidebarDragSpring.move(history.place(layout, state: state, metrics: .standard, in: list, animated: true), in: list)

        #expect(Self.positionSprings(block) == 0, "the block kept its spring with movement off")
        #expect(block.frame == slot)
    }
}
