import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Leo 2026-10-21: "right now adding a workspace at the top ... it pushes all the stuff down". The rows
/// below an insert make room on the render server's spring (`RowMotion.animate`, `SidebarDragSpring`): each
/// row's frame is at its slot at once and an additive spring carries what is on screen there, so the main
/// thread writes no row frame per display frame. AppKit's spring wrote every moving row's frame each frame.
@MainActor @Suite(.serialized)
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
            window.orderOut(nil)
        })
    }

    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func anInsertAtTheTopMovesTheRowsBelowOnTheRenderServer() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        let shown = list.rowViews.compactMap { key, view -> (SidebarRowKey, SidebarRowView, CGFloat)? in
            if case .workspace = key { (key, view, view.frame.minY - clip.bounds.minY) } else { nil }
        }

        model.sections = Self.sections([0] + Array(1...30))
        list.reload(animated: true)

        // The rows the insert pushed down on screen (the list's top holds still, so all of them).
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
        #expect(moved > 3, "the insert at the top pushed \(moved) rows down (of \(shown.count) shown)")
        let added = try #require(Self.sections([0]).first?.workspaces.first?.id)
        let opening = try #require(list.rowViews[.workspace(added)], "the new row at the top has no view")
        let slot = try #require(list.displayed.row(for: opening.key).map(list.frame(for:)))
        #expect(opening.frame == slot, "the new row is at \(opening.frame), its slot is \(slot)")
        #expect(Self.sizeSprings(opening) >= 1, "the new row did not open its slot on the render server")
        #expect(opening.alphaValue < 1, "the new row showed whole in one frame")
    }

    /// Leo 2026-10-21: "when you create a workspace at the top it's a huge cascade". Under the default
    /// `sidebar.insertMotion` (nudge) each row below a new row near the top travels at most the nudge, not a row height, and the
    /// new row opens only its last nudge of height, on a spring that is at rest by 150 ms (`SidebarInsertMotionTests`).
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aNewRowNearTheTopNudgesTheRowsBelowByAtMostTheNudge() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
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
        try #require(SidebarInsertMotion.tunable.value == .nudge)
        let key = SidebarRowKey.workspace(try #require(Self.sections([0]).first?.workspaces.first?.id))

        model.noteUserIntent()
        model.sections = Self.sections([1, 0] + Array(2...30))
        list.reload(animated: true)
        let inserted = CACurrentMediaTime()
        let view = try #require(list.rowViews[key])
        let until = try #require(list.openingRows[key])
        let open = Motion.sidebar.spring(SidebarInsertMotion.nudge.token).settlingTime()
        #expect(abs(until - inserted - open) < 0.02, "the open lasts \(until - inserted) s, its spring settles in \(open) s")
        #expect(open < Motion.sidebar.spring(.move).settlingTime())

        RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0, until - CACurrentMediaTime()) + 0.01))
        let sizing = Self.sizeSprings(view)
        model.noteUserIntent()
        model.sections = Self.sections([1, 2, 0] + Array(3...30))
        list.reload(animated: true)

        #expect(list.rowViews[key] === view, "the settled row opened again in a new view")
        #expect(Self.sizeSprings(view) <= sizing, "the settled row opened its slot again")
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
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(SidebarInsertMotion.spring.rawValue))
        defer { TunableStore.shared.set(SidebarInsertMotion.tunable.key, nil) }
        try #require(SidebarInsertMotion.tunable.value == .spring)
        let key = SidebarRowKey.workspace(try #require(Self.sections([1]).first?.workspaces.first?.id))
        let view = try #require(list.rowViews[key])

        model.sections = Self.sections([0] + Array(1...30))
        list.reload(animated: true)
        try #require(Self.positionSprings(view) == 1)
        model.sections = Self.sections([999, 0] + Array(1...30))
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
        model.sections = Self.sections([0] + Array(1...30))
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
        model.sections = Self.grouped(["new"] + (1...8).map { "w\($0)" })
        list.reload(animated: true)
        try #require(!Self.springing(list).isEmpty, "the insert did not move on the render server")

        model.sections = Self.grouped(["new"] + (1...7).map { "w\($0)" })
        list.reload(animated: false)

        #expect(Self.springing(list).isEmpty, "still springing after a reload without motion: \(Self.springing(list))")
        #expect(Self.offSlot(list).isEmpty, "not at their slots: \(Self.offSlot(list))")
    }

    /// Reduce Motion turned on mid-move: the next change snaps, the earlier move's springs with it.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func reduceMotionMidMoveShowsTheSlotsAtOnce() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.grouped((1...8).map { "w\($0)" }))
        defer { restore() }
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
