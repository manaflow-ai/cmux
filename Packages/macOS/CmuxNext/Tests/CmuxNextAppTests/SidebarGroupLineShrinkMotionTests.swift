import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// #21999 review: a group's members' line that shrinks (a member closes, the group closes)
/// jumped to its end length at once, or vanished while it still faded, where base shrank it
/// with its rows. With `sidebar.groupLineJoinsHeader` off the line's trimmed ends were a mask
/// laid out at the line's end size, and on, the joined bar's outline took its end length in one
/// frame. The line follows its group's last row in every frame of the rows' spring, joined or not.
@MainActor @Suite(.serialized) struct SidebarGroupLineShrinkMotionTests {
    private static let group = GroupID("grp-shrink")
    private static let members = ["ws-a", "ws-b", "ws-c"].map { WorkspaceID($0) }

    private static func sections(_ members: [WorkspaceID]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = members.map { SidebarWorkspace(id: $0, title: $0.rawValue) }
        return [SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, workspaces: workspaces)),
        ])]
    }

    private static func sidebar(joined: Bool) -> (SidebarView, SidebarModel) {
        let model = SidebarModel(sections: sections(members))
        let design = DesignSettings()
        design.sidebarSections.groupLineJoinsHeader = joined
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        // The settings reach the list on an observation a turn later; draw them in this turn.
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, model)
    }

    /// Mid-shrink the line's presented size is still taller than the size it was last laid out
    /// at: Core Animation draws each frame of the rows' spring at the presented size and never
    /// lays the view out again. What the line draws reaches both ends of that size.
    @Test func aShrinkingLinesEndsFollowItsPresentedSize() throws {
        let (sidebar, _) = Self.sidebar(joined: false)
        let line = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first, "no members' line")
        line.layoutSubtreeIfNeeded()
        line.updateLayer()
        let layer = try #require(line.layer)
        let laidOut = layer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds.size.height = laidOut.height + 40 // a frame early in the shrink
        CATransaction.commit()
        if let mask = layer.mask {
            #expect(abs(mask.frame.maxY - layer.bounds.maxY) < 0.01,
                    "the line's ends are a mask laid out at \(laidOut.height) pt: the \(layer.bounds.height) pt line shows cut to it")
        }
        #expect(layer.contents != nil || layer.backgroundColor != nil, "the line draws nothing")
        // Its own contents stretch between ends that keep their size.
        if layer.mask == nil {
            #expect(layer.contentsCenter.height < 1 && layer.contentsCenter.minY > 0, "the line's trimmed ends stretch with it")
        }
    }

    /// Joined, a line closing back toward its bar springs its length with the rows (the rows'
    /// own `.move` spring), not in one frame. Movement must animate: a window on screen.
    @Test(.enabled("a window with no screen applies its changes at once") { await SidebarCalmMotionTests.hasDisplay() })
    func aJoinedLineShrinksWithItsRows() throws {
        let (sidebar, model) = Self.sidebar(joined: true)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        let before = header.barLayer.frame.height
        let springs = { () -> (animated: Bool, end: CGFloat) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            model.sections = Self.sections(Array(Self.members.dropLast()))
            sidebar.list.reload(animated: true)
            header.layoutSubtreeIfNeeded()
            return (header.barLayer.animation(forKey: "bounds") != nil, header.barLayer.frame.height)
        }()
        #expect(springs.end < before - 1, "the joined line did not shrink (\(before) to \(springs.end) pt)")
        #expect(springs.animated, "the joined line took its \(springs.end) pt length in one frame, from \(before) pt")
    }

    /// The joined outline's own writes never animate on their own: Core Animation's implicit
    /// 0.25 s action on a standalone mask ignores the motion switches and Reduce Motion, so a
    /// non-animated reload (a scroll reusing the header, a resize) would tween it. Only the gated
    /// springs (`Motion.sidebar.set`, which add their animation explicitly) may move it.
    @Test func aJoinedOutlineHasNoImplicitAnimations() throws {
        let (sidebar, _) = Self.sidebar(joined: true)
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        let outline = try #require(header.barLayer.mask, "the joined bar has no outline")
        for key in ["bounds", "position", "anchorPoint", "path"] {
            #expect(outline.action(forKey: key) == nil, "the outline's \(key) animates on its own")
        }
        #expect(header.barLayer.action(forKey: "cornerRadius") == nil, "the bar's corners animate on their own")
    }

    /// A layout during the rows' spring (a hover, a focus change) keeps the outline on that spring:
    /// it does not swap it for an implicit animation and snap the outline to its end.
    @Test(.enabled("a window with no screen applies its changes at once") { await SidebarCalmMotionTests.hasDisplay() })
    func aLayoutMidSpringKeepsTheJoinedLinesSpring() throws {
        let (sidebar, model) = Self.sidebar(joined: true)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        CATransaction.flush() // Core Animation animates only layers it has committed once
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        model.sections = Self.sections(Array(Self.members.dropLast()))
        sidebar.list.reload(animated: true)
        header.layoutSubtreeIfNeeded()
        CATransaction.flush()
        header.needsLayout = true // a hover mid-spring
        header.layoutSubtreeIfNeeded()
        let outline = try #require(header.barLayer.mask, "the joined bar has no outline")
        #expect(outline.animation(forKey: "path") is CASpringAnimation, "a layout mid-spring replaced the outline's spring")
        #expect(outline.animation(forKey: "bounds") is CASpringAnimation, "a layout mid-spring replaced the outline's spring")
    }
}
