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

    /// A second insert while the first one's rows still move: each row keeps the first spring and adds one
    /// from where it is now, so nothing on screen jumps back to the first move's end.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aSecondInsertStacksOnTheFirstMove() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
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
