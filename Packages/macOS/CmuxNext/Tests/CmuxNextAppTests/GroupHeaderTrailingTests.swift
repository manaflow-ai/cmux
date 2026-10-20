import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20 (u-group-header-detail): "Group settings don't show too much detail by
/// default. All we care about is the loading." A collapsed group header shows only its loading
/// spinner on the right by default: no member count, no unread count, no other status. And the
/// header's trailing items close up: with nothing loading the spinner leaves no hole, and the
/// spinner sits right beside the chevron at rest and right beside the + and more on hover.
@MainActor @Suite(.serialized) struct GroupHeaderTrailingTests {
    static let group = GroupID("grp-trailing")

    /// A sidebar with one collapsed group of two workspaces: the first `activity`, the second
    /// with 3 unread notifications. The header offers + (an App that runs group actions).
    static func header(activity: StatusIndicatorState, name: String = "Agents & routing",
                       design: DesignSettings = DesignSettings()) throws -> (GroupHeaderRowView, SidebarView) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: (0..<2).map { index in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: "ws-\(index)"), name: "w\(index)")
        }))
        let section = try #require(SidebarMapping.shared.sections(store.sidebarSections,
                                                                   machine: SidebarMachine(id: .local, name: "This Mac", kind: .local)).first)
        var members = section.workspaces
        try #require(members.count == 2)
        members[0].activity = activity
        members[1].unread = .count(3)
        let node = CmuxNextSidebar.SidebarNode.group(SidebarGroup(id: group, name: name, color: .blue, isCollapsed: true, workspaces: members))
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: [node])])
        let sidebar = SidebarView(model: model, design: design)
        sidebar.list.onGroupEditorItem = { _, _ in }
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        // The settings reach the list on an observation a turn later; draw them in this turn.
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        sidebar.list.wire(header, key: .group(group))
        header.layoutSubtreeIfNeeded()
        return (header, sidebar)
    }

    static func views<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { sub in ((sub as? View).map { [$0] } ?? []) + views(type, in: sub) }
    }

    /// The spinner's frame in the header, nil when it does not show.
    static func spinner(_ header: GroupHeaderRowView) -> CGRect? {
        guard let view = views(StatusIndicatorView.self, in: header).first, !isHidden(view, in: header), view.showsGlyph else { return nil }
        return header.convert(view.bounds, from: view)
    }

    /// Whether `view` or a view between it and `root` is hidden.
    static func isHidden(_ view: NSView, in root: NSView) -> Bool {
        var current: NSView? = view
        while let node = current, node !== root {
            if node.isHidden || node.alphaValue == 0 { return true }
            current = node.superview
        }
        return false
    }

    static func chevron(_ header: GroupHeaderRowView) throws -> CGRect {
        try #require(header.debugDisclosure?.frame)
    }

    static func hover(_ header: GroupHeaderRowView, _ on: Bool) {
        header.isHovered = on
        header.layoutSubtreeIfNeeded()
    }

    /// The most space two neighbouring trailing items keep between them.
    static let neighbourGap = Metrics.space2 + 0.5

    @Test func aCollapsedHeaderShowsNoMemberOrUnreadCountByDefault() throws {
        let (header, _) = try Self.header(activity: .working)
        #expect(header.countText == nil, "a collapsed header shows its member count \(header.countText ?? "") by default")
        let badges = Self.views(UnreadBadgeView.self, in: header).filter { !Self.isHidden($0, in: header) }
        #expect(badges.isEmpty, "a collapsed header shows its unread count by default")
        #expect(Self.spinner(header) != nil, "a collapsed header with a working member shows no spinner")
    }

    @Test func aCollapsedHeaderShowsNoStatusButLoadingByDefault() throws {
        let (header, _) = try Self.header(activity: .waiting)
        #expect(Self.spinner(header) == nil, "a collapsed header shows a waiting member's status by default")
    }

    @Test func theSpinnerSitsBesideTheChevronAtRest() throws {
        let (header, _) = try Self.header(activity: .working)
        Self.hover(header, false)
        let spinner = try #require(Self.spinner(header))
        let chevron = try Self.chevron(header)
        #expect(chevron.minX - spinner.maxX <= Self.neighbourGap,
                "the spinner ends at \(spinner.maxX), \(chevron.minX - spinner.maxX) pt short of the chevron at \(chevron.minX)")
    }

    @Test func theSpinnerSitsBesideTheButtonsOnHover() throws {
        let (header, _) = try Self.header(activity: .working)
        Self.hover(header, true)
        let spinner = try #require(Self.spinner(header))
        let chevron = try Self.chevron(header)
        let more = header.moreButton.frame, add = header.addButton.frame
        #expect(chevron.minX - more.maxX <= Self.neighbourGap, "a gap between the more button and the chevron")
        #expect(more.minX - add.maxX <= Self.neighbourGap, "a gap between + and the more button")
        #expect(add.minX - spinner.maxX <= Self.neighbourGap && spinner.maxX <= add.minX,
                "the spinner ends at \(spinner.maxX), not beside + at \(add.minX)")
    }

    /// Nothing loading and no hover: the name may run up to the chevron; no empty slot is kept.
    @Test func withNothingLoadingTheNameRunsToTheChevron() throws {
        let long = "A group whose name is long enough to run past the reserved button slots"
        let (header, _) = try Self.header(activity: .idle, name: long)
        Self.hover(header, false)
        #expect(Self.spinner(header) == nil)
        let chevron = try Self.chevron(header)
        let gap = chevron.minX - header.titleFrame.maxX
        #expect(gap <= Self.neighbourGap + Metrics.space1, "the name stops \(gap) pt before the chevron: an empty gap")
    }
}
