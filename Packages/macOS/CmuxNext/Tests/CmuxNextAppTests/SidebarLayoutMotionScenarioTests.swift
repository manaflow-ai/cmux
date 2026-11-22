import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The native sidebar's half of the layout-motion scenario table (schemas/layout-motion/contract.json). Leo,
/// 2026-11-18: "I was thinking we'd be able to calculate each beforehand everything that would move and just go
/// ok well nothing else usually should and the things that move we only expect at certain times etc ...
/// Fundamentally", then: "And then likewise, of course, we want that for the sidebar. And we want things to be
/// fast." Each scenario drives the real `SidebarView` through one moment (load, a workspace switch, a new
/// workspace, a status change, a group opening, a resize), samples every drawn row and badge in window
/// coordinates after each render, and judges the frames with the contract's judge (LayoutMotionJudge, the same
/// rules and vectors as the pages'). A move the contract does not declare for the moment fails the test, and
/// every scenario prints its count (`LAYOUT-MOTION sidebar <scenario> undeclared=N`) for the scenario table.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarLayoutMotionScenarioTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private static let group = GroupID("motion-group")

    private static func workspace(_ index: Int, status: String? = nil, unread: UnreadState = .none,
                                  activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID("ws-\(index)"), title: "workspace \(index)")
        row.status = status
        row.unread = unread
        row.activity = activity
        return row
    }

    private static func sections(count: Int = 10, groupOpen: Bool = false,
                                 change: (Int, inout SidebarWorkspace) -> Void = { _, _ in }) -> [SidebarSection] {
        let loose: [SidebarNode] = (0..<count).map { index in
            var row = workspace(index)
            change(index, &row)
            return .workspace(row)
        }
        let members = (100..<104).map { workspace($0) }
        let grouped = SidebarNode.group(SidebarGroup(id: group, name: "cosmic-gray", isCollapsed: !groupOpen, workspaces: members))
        return [SidebarSection(kind: .machine(machine), nodes: Array(loose.prefix(4)) + [grouped] + Array(loose.dropFirst(4)))]
    }

    /// One sidebar in a window that is never ordered front, so nothing animates and nothing steals focus.
    private final class Stage {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var frames: [LayoutMotionFrame] = []
        /// The row an expand opens: it and what it holds may move, and rows after it only straight down.
        var target: SidebarRowKey?

        init(sections: [SidebarSection]) {
            model = SidebarModel(sections: sections, activeWorkspaceID: WorkspaceID("ws-0"))
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 640)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
        }

        /// One drawn frame: the sidebar renders, lays out and runs its pending main-queue work, then every row
        /// view and badge is read where it is on screen.
        func draw(_ declared: [LayoutMotionDeclaration] = []) {
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            sidebar.layoutSubtreeIfNeeded()
            frames.append(LayoutMotionFrame(samples: sample(), declared: declared))
        }

        func sample() -> [String: LayoutMotionSample] {
            var samples: [String: LayoutMotionSample] = [:]
            let visible = downward(sidebar.convert(sidebar.bounds, to: nil))
            let order = Dictionary(sidebar.list.displayed.rows.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
            let targetIndex = target.flatMap { order[$0] }
            samples["list"] = LayoutMotionSample(label: "list", surface: "sidebar-list", box: visible)
            for (key, view) in sidebar.list.rowViews where !view.isHiddenOrHasHiddenAncestor && view.window != nil {
                let box = downward(view.convert(view.bounds, to: nil))
                guard box.intersects(visible) else { continue }
                let rowIndex = order[key]
                let targeted = key == target
                let after = !targeted && targetIndex != nil && (rowIndex ?? 0) > targetIndex!
                samples["row \(key)"] = LayoutMotionSample(label: "row \(key)", surface: "sidebar-row", box: box,
                                                           targeted: targeted, after: after)
                for (index, badge) in Self.badges(in: view).enumerated() {
                    samples["badge \(key) #\(index)"] = LayoutMotionSample(
                        label: "badge \(key) #\(index)", surface: "sidebar-badge", box: downward(badge.convert(badge.bounds, to: nil)),
                        targeted: targeted, after: after)
                }
            }
            return samples
        }

        /// A window rect in the judge's coordinates. AppKit window coordinates grow upward and the contract's
        /// (like the pages') grow downward, so a row an expand pushes down must read as a positive `dy`, or the
        /// judge's "rows after the target move only straight down" rule flags every legitimate expand.
        func downward(_ rect: CGRect) -> CGRect {
            let height = window.contentView?.bounds.height ?? window.frame.height
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }

        static func badges(in view: NSView) -> [NSView] {
            view.subviews.flatMap { subview -> [NSView] in
                guard !subview.isHidden else { return [] }
                return (subview is RowBadgeView ? [subview] : []) + badges(in: subview)
            }
        }

        /// The first draws, until the sidebar has rested (the contract's rest frames).
        func load() {
            for _ in 0..<4 { draw() }
        }

        /// The moment `act`, declared as `declared`, then the frames after it until it settles.
        func play(_ declared: [LayoutMotionDeclaration] = [], _ act: () -> Void) {
            act()
            draw(declared)
            for _ in 0..<6 { draw() }
        }

        func verdict() throws -> LayoutMotionVerdict {
            judgeLayoutMotion(frames, contract: try LayoutMotionContract.load())
        }
    }

    private static func judge(_ scenario: String, _ stage: Stage) throws {
        defer { stage.window.close() }
        let verdict = try stage.verdict()
        print("LAYOUT-MOTION sidebar \(scenario) undeclared=\(verdict.undeclared) frames=\(stage.frames.count) rows=\(stage.frames.last?.samples.count ?? 0)")
        #expect(verdict.undeclared == 0, "\(scenario): undeclared sidebar moves: \(verdict.moves)")
    }

    @Test func loadDrawsEveryRowAtItsFinalPlace() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        stage.play {}
        try Self.judge("load", stage)
    }

    @Test func aWorkspaceSwitchMovesNoRow() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        stage.play { stage.model.selectedItem = .workspace(WorkspaceID("ws-7")) }
        stage.play { stage.model.selectedItem = .workspace(WorkspaceID("ws-2")) }
        try Self.judge("workspace-switch", stage)
    }

    @Test func aNewWorkspaceMovesOnlyTheRowsAfterIt() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        // A new workspace is a person's change to the list: the rows after its place move once to make room.
        stage.play([LayoutMotionDeclaration(key: 1, event: "reorder", scope: .all, once: true)]) {
            stage.model.setSections(Self.sections(count: 11))
            stage.model.selectedItem = .workspace(WorkspaceID("ws-10"))
        }
        try Self.judge("new-workspace", stage)
    }

    @Test func aStatusChangeMovesNothing() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        // Status, unread and activity marks have reserved slots: nothing is declared, so nothing may move.
        stage.play {
            stage.model.setSections(Self.sections { index, row in
                if index == 1 { row.activity = .busy(progress: nil) }
                if index == 2 { row.unread = .count(3) }
                if index == 3 { row.status = "waiting for input" }
            })
        }
        stage.play {
            stage.model.setSections(Self.sections { index, row in
                if index == 1 { row.activity = .idle }
                if index == 2 { row.unread = .count(12) }
                if index == 3 { row.status = nil }
            })
        }
        try Self.judge("status", stage)
    }

    @Test func openingAGroupPushesOnlyWhatFollowsIt() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        stage.target = .group(Self.group)
        stage.play([LayoutMotionDeclaration(key: 1, event: "expand", scope: .targets)]) {
            stage.model.setSections(Self.sections(groupOpen: true))
        }
        try Self.judge("group-expand", stage)
    }

    @Test func aResizeLaysEachRowOutOnce() throws {
        let stage = Stage(sections: Self.sections())
        stage.load()
        for (key, width) in [(1, 300.0), (2, 220.0), (3, 260.0)] {
            stage.play([LayoutMotionDeclaration(key: key, event: "resize", scope: .all, once: true)]) {
                stage.sidebar.frame.size.width = width
                stage.window.setContentSize(NSSize(width: width, height: 640))
            }
        }
        try Self.judge("resize", stage)
    }
}
