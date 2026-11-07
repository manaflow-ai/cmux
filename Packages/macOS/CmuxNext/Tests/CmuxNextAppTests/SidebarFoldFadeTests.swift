import AppKit
import CmuxNextBridge
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-11-05 (ask-71821f1cda): "when you're collapsing a group, the text needs to fade faster. Otherwise, you just
/// get a ton of text like just jumbled up inside". The rows a collapse hides fade out on `fadeOut`, not over the `.move`
/// spring their slot closes on (`RowMotion.folding`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarFoldFadeTests {
    private static func ws(_ id: String) -> CmuxNextSidebar.SidebarWorkspace { CmuxNextSidebar.SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID(id), title: id) }

    /// w1, group Work (docs, web, api; open), then w9 below it.
    private static func workThenBelow() -> [CmuxNextSidebar.SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let work = CmuxNextSidebar.SidebarGroup(id: GroupID("g-work"), name: "Work", color: .blue, workspaces: ["docs", "web", "api"].map(ws))
        return [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w1")), .group(work), .workspace(ws("w9"))])]
    }

    /// `start` in a window on screen, its first workspace selected, with Reduce Motion off.
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
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, window, {
            Motion.reduceMotionOverride = nil
            window.close()
        })
    }

    /// Leo 2026-11-05 (ask-71821f1cda): "when you're collapsing a group, the text needs to fade faster ... you still see
    /// like overlapping text sometimes". The members' text fades out on the short `fadeOut`, well inside the `.move`
    /// spring the slot closes on, so no member's text is still showing when the rows below rise over its place.
    @Test(.enabled("needs an awake display and animations on, or every fold snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func collapsingAGroupFadesItsMembersOutBeforeTheSlotCloses() throws {
        let (model, list, _, restore) = try Self.sidebar(Self.workThenBelow())
        defer { restore() }
        let members = try ["docs", "web", "api"].map { member in
            (member, try #require(list.rowViews[.workspace(CmuxNextSidebar.WorkspaceID(member))], "\(member) has no view"))
        }
        model.noteUserIntent()
        model.setGroupCollapsed(GroupID("g-work"), true)
        let moveDuration = Motion.sidebar.springAnimation(.move, "position", from: 0, to: 0).duration
        let fadeOut = Motion.sidebar.duration(.fadeOut)
        try #require(fadeOut > 0 && fadeOut < moveDuration / 2, "fadeOut (\(fadeOut) s) is not well under .move (\(moveDuration) s)")
        for (name, view) in members {
            let fade = try #require(view.layer?.animation(forKey: "opacity") as? CABasicAnimation, "\(name) does not fade on its layer")
            #expect(!(fade is CASpringAnimation), "\(name) fades on a spring, over the slot's whole close")
            #expect(abs(fade.duration - fadeOut) < 0.001, "\(name) fades for \(fade.duration) s, fadeOut is \(fadeOut) s")
            #expect((fade.toValue as? Float) == 0)
            #expect(view.alphaValue == 0, "\(name)'s opacity does not end at 0")
        }
    }

    /// Codex review of #36457: a collapse that reaches the list as a reload (`apply`) hides a nested group's members
    /// too; they fade on `fadeOut` like the outer group's own, not over the whole `.move` spring.
    @Test(.enabled("needs an awake display and animations on, or every fold snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func collapsingAParentGroupFadesItsNestedMembersOutFast() throws {
        func nested(collapsed: Bool) -> [CmuxNextSidebar.SidebarSection] {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let outer = CmuxNextSidebar.SidebarGroup(id: GroupID("g-outer"), name: "Outer", color: .blue, isCollapsed: collapsed,
                                                     workspaces: [Self.ws("docs")])
            var inner = CmuxNextSidebar.SidebarGroup(id: GroupID("g-inner"), name: "Inner", color: .green, workspaces: ["web", "api"].map(Self.ws))
            inner.parent = GroupID("g-outer")
            inner.depth = 1
            return [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [.workspace(Self.ws("w1")), .group(outer), .group(inner),
                                                                                    .workspace(Self.ws("w9"))])]
        }
        let (model, list, _, restore) = try Self.sidebar(nested(collapsed: false))
        defer { restore() }
        let inner = try ["web", "api"].map { member in
            (member, try #require(list.rowViews[.workspace(CmuxNextSidebar.WorkspaceID(member))], "\(member) has no view"))
        }
        try #require(inner.allSatisfy { list.displayed.row(for: $0.1.key)?.depth == 2 }, "the inner group's members are not nested")
        model.noteUserIntent()
        model.sections = nested(collapsed: true)
        list.reload(animated: true)
        let fadeOut = Motion.sidebar.duration(.fadeOut)
        for (name, view) in inner {
            try #require(list.rowViews[view.key] == nil, "\(name) still shows under the collapsed group")
            let fade = try #require(view.layer?.animation(forKey: "opacity") as? CABasicAnimation, "\(name) does not fade on its layer")
            #expect(abs(fade.duration - fadeOut) < 0.001, "\(name) fades for \(fade.duration) s, fadeOut is \(fadeOut) s")
        }
    }
}
