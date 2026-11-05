import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// https://github.com/manaflow-ai/cmux/issues/34264: Cmd-Shift-T animated the whole sidebar. A reopened workspace is
/// listed unplaced, first in its machine section, until the daemon's echo moves it to its slot
/// (`SidebarDocProjection.item(of:id:records:)`); that move slid every row between the top and the slot on `.move`.
/// No change animates more of the sidebar than the rows it changes: a row another change only shifts stands in its new
/// slot at once, with no spring, at full opacity, and a reveal jumps instead of sliding the list.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarChangedRowsMotionTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func ws(_ id: String) -> CmuxNextSidebar.SidebarWorkspace { CmuxNextSidebar.SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID(id), title: id) }

    /// w1, group Work (docs, web, api; open unless `collapsed`), then w2 to w9 below it.
    private static func workThenBelow(collapsed: Bool = false) -> [CmuxNextSidebar.SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let work = CmuxNextSidebar.SidebarGroup(id: GroupID("g-work"), name: "Work", color: .blue, isCollapsed: collapsed,
                                                workspaces: ["docs", "web", "api"].map(ws))
        return [CmuxNextSidebar.SidebarSection(kind: .machine(machine),
                                               nodes: [.workspace(ws("w1")), .group(work)] + (2...9).map { .workspace(ws("w\($0)")) })]
    }

    private static func key(_ id: Int) throws -> SidebarRowKey {
        .workspace(try #require(sections([id]).first?.workspaces.first?.id))
    }

    /// The render server's additive springs on `view`'s layer (`SidebarDragSpring`).
    private static func springs(_ view: NSView) -> Int {
        guard let layer = view.layer else { return 0 }
        return (layer.animationKeys() ?? []).filter { key in
            (layer.animation(forKey: key) as? CASpringAnimation)?.isAdditive ?? false
        }.count
    }

    /// The keys of the animations that move `view` or fade it (a spring, AppKit's frame animator, a pass-over hide).
    private static func motion(_ view: NSView) -> [String] {
        guard let layer = view.layer else { return [] }
        let paths: Set<String> = ["position", "bounds", "bounds.size", "bounds.origin", "frameOrigin", "frameSize", "opacity"]
        return (layer.animationKeys() ?? []).filter { key in
            (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath.map(paths.contains) ?? (layer.animation(forKey: key) is CAAnimationGroup)
        }
    }

    /// Each realized row except `changed` that springs, is off its layout slot or is not opaque: rows the change only
    /// shifted, which must stand still in their new slots.
    private static func movedBystanders(_ list: SidebarListView, except changed: Set<SidebarRowKey>) -> [String] {
        list.rowViews.compactMap { key, view -> String? in
            guard !changed.contains(key) else { return nil }
            guard let row = list.displayed.row(for: key) else { return "\(key) has no row" }
            let slot = list.frame(for: row)
            let animations = motion(view)
            guard view.frame == slot, view.alphaValue == 1, animations.isEmpty else {
                return "\(key) at \(view.frame) (slot \(slot)) alpha \(view.alphaValue) animations \(animations)"
            }
            return nil
        }.sorted()
    }

    /// `start` in a window on screen, its first workspace selected, the list at its top, Reduce Motion off and new
    /// workspace rows opening.
    private static func sidebar(_ start: [CmuxNextSidebar.SidebarSection], height: CGFloat = 480) throws
        -> (SidebarModel, SidebarListView, NSWindow, restore: () -> Void) {
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: height)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        if window.screen == nil { window.close() }
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        Motion.reduceMotionOverride = false
        // New workspace rows open (`ui.animations.newWorkspace`, off by default), so the reopened row's listing and an
        // expanded group's members take the animated path too.
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        return (model, sidebar.list, window, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            window.close()
        })
    }

    /// The reopen: w5 is drawn first in the section (unplaced), then the echo moves it to its slot. Neither step
    /// moves any other row.
    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aReopenedWorkspaceMovingToItsSlotMovesNoOtherRow() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.sections(Array(1...4) + Array(6...30)))
        defer { restore() }
        let reopened = try Self.key(5)

        model.noteUserIntent()
        model.sections = Self.sections([5] + Array(1...4) + Array(6...30))
        list.reload(animated: true)
        #expect(Self.movedBystanders(list, except: [reopened]).isEmpty,
                "listing the reopened row moved others: \(Self.movedBystanders(list, except: [reopened]))")

        model.noteUserIntent()
        model.sections = Self.sections(Array(1...30))
        list.reload(animated: true)
        #expect(Self.movedBystanders(list, except: [reopened]).isEmpty,
                "the reopened row's move to its slot moved others: \(Self.movedBystanders(list, except: [reopened]))")
        let view = try #require(list.rowViews[reopened])
        #expect(view.frame == list.frame(for: try #require(list.displayed.row(for: reopened))), "the reopened row is not at its slot")
    }

    /// A close: the rows below take the closed row's slot at once, and the closed row is gone (it cannot fade in a
    /// slot they already stand in).
    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aCloseMovesNoOtherRow() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.sections(Array(1...30)))
        defer { restore() }
        let closing = try #require(list.rowViews[try Self.key(3)])

        model.noteUserIntent()
        model.sections = Self.sections([1, 2] + Array(4...30))
        list.reload(animated: true)

        #expect(Self.movedBystanders(list, except: []).isEmpty, "the close moved others: \(Self.movedBystanders(list, except: []))")
        #expect(closing.isHidden || closing.superview == nil, "the closed row still draws over the rows in its slot")
    }

    /// A move (Move Workspace Up, a reorder from another entrypoint): no row slides.
    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aMoveSlidesNoRow() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.sections(Array(1...30)))
        defer { restore() }

        model.noteUserIntent()
        model.sections = Self.sections([1, 8, 2, 3, 4, 5, 6, 7] + Array(9...30))
        list.reload(animated: true)

        #expect(Self.movedBystanders(list, except: []).isEmpty, "the move slid rows: \(Self.movedBystanders(list, except: []))")
    }

    /// A group's fold: the rows below it take their new slots at once, both ways.
    @Test(.enabled("needs an awake display and animations on, or every fold snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aFoldMovesNoRowOutsideTheGroup() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.workThenBelow())
        defer { restore() }
        let members = Set(["docs", "web", "api"].map { SidebarRowKey.workspace(CmuxNextSidebar.WorkspaceID($0)) })
        let header = SidebarRowKey.group(GroupID("g-work"))

        model.noteUserIntent()
        model.setGroupCollapsed(GroupID("g-work"), true)
        #expect(Self.movedBystanders(list, except: [header]).isEmpty, "the collapse moved others: \(Self.movedBystanders(list, except: [header]))")

        model.noteUserIntent()
        model.setGroupCollapsed(GroupID("g-work"), false)
        #expect(Self.movedBystanders(list, except: members.union([header])).isEmpty,
                "the expand moved others: \(Self.movedBystanders(list, except: members.union([header])))")
        for key in members {
            let view = try #require(list.rowViews[key], "\(key) has no view")
            #expect(view.frame == list.frame(for: try #require(list.displayed.row(for: key))), "\(key) does not open at its own slot")
            #expect(Self.springs(view) == 0, "\(key) slides out from under the header")
            #expect(view.alphaValue < 1, "\(key) showed whole in one frame instead of fading in at its slot")
        }
    }

    /// A selection far below the viewport: the list jumps to it in the change's own turn instead of sliding every
    /// row past on a scroll.
    @Test(.enabled("needs an awake display and animations on, or every scroll snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aRevealJumpsInsteadOfSlidingTheList() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.sections(Array(1...80)), height: 320)
        defer { restore() }
        let target = try Self.key(70)
        let clip = try #require(list.enclosingScrollView?.contentView)
        try #require(clip.bounds.minY < 1, "the list did not start at its top")

        model.noteUserIntent()
        model.activeWorkspaceID = try #require(Self.sections([70]).first?.workspaces.first?.id)
        list.reload(animated: true)

        let row = try #require(list.displayed.row(for: target))
        #expect(row.y >= clip.bounds.minY && row.y + row.height <= clip.bounds.maxY,
                "the selected row at \(row.y) is not in view at \(clip.bounds.minY)...\(clip.bounds.maxY) after its change: the list slides")
    }
}
