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
/// spinner takes the chevron's place at rest. Leo 2026-10-28 ("If you're hovering over a workspace or whatever,
/// just don't show the spinner"): a hover hides it at once, and the chevron, more and + show in its place.
/// Lawrence msg 11983 ("make sure sidebar has blue, orange/yellow for needs attention, and red for
/// errors") adds the members' most urgent state: red, then orange, then the blue unread dot.
@MainActor @Suite(.serialized) struct GroupHeaderTrailingTests {
    static let group = GroupID("grp-trailing")

    /// A sidebar with one collapsed group of two workspaces: the first `activity`, the second
    /// `unread` (3 notifications by default). The header offers + (an App that runs group actions).
    static func header(activity: StatusIndicatorState, unread: UnreadState = .count(3), name: String = "Agents & routing",
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
        members[1].unread = unread
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

    /// The chevron's view (the header's one `DisclosureChevronView` at the chevron's frame).
    static func chevronView(_ header: GroupHeaderRowView) -> NSView? {
        guard let frame = header.debugDisclosure?.frame else { return nil }
        return header.subviews.first { $0 is DisclosureChevronView && $0.frame == frame }
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
        let (header, _) = try Self.header(activity: .working, unread: .none)
        #expect(header.countText == nil, "a collapsed header shows its member count \(header.countText ?? "") by default")
        let badges = Self.views(UnreadBadgeView.self, in: header).filter { !Self.isHidden($0, in: header) }
        #expect(badges.isEmpty, "a collapsed header shows its unread count by default")
        #expect(Self.spinner(header) != nil, "a collapsed header with a working member shows no spinner")
    }

    @Test func theSettingsBringTheCountsBack() throws {
        let design = DesignSettings()
        design.sidebarSections.groupHeaderMemberCount = true
        design.sidebarSections.groupHeaderUnreadCount = true
        let (header, sidebar) = try Self.header(activity: .working, design: design)
        _ = sidebar
        #expect(header.countText == "2", "the member count setting shows no count")
        let badges = Self.views(UnreadBadgeView.self, in: header).filter { !Self.isHidden($0, in: header) }
        #expect(badges.count == 1, "the unread count setting shows no unread count")
    }

    /// Lawrence msg 11983: a collapsed header shows its members' most urgent state (a waiting member
    /// outranks another's unread: needs you, orange), and with neither only its loading.
    @Test func aCollapsedHeaderShowsItsMostUrgentMemberState() throws {
        let (header, _) = try Self.header(activity: .waiting)
        #expect(Self.spinner(header) != nil, "a collapsed header hides a waiting member's needs-you dot")
        #expect(Self.views(StatusIndicatorView.self, in: header).first?.state == .waiting)
        let (paused, _) = try Self.header(activity: .paused(progress: nil), unread: .none)
        #expect(Self.spinner(paused) == nil, "a collapsed header shows a paused member's status")
    }

    /// Lawrence 2026-10-20: the spinner sits at the far right edge, where the chevron is, while
    /// the pointer is away (on the trailing column a296 lines every dot and spinner up on).
    @Test func theSpinnerSitsOnTheChevronColumnAtRest() throws {
        let (header, _) = try Self.header(activity: .working, unread: .none)
        Self.hover(header, false)
        let spinner = try #require(Self.spinner(header))
        let column = SidebarStyle.trailingColumnCenterX(rowWidth: header.bounds.width)
        #expect(abs(spinner.midX - column) <= 0.5, "the spinner is centered at \(spinner.midX), not on the chevron column at \(column)")
        let chevron = try #require(Self.chevronView(header))
        #expect(Self.isHidden(chevron, in: header), "the chevron still shows under the spinner at rest")
    }

    /// Nothing loading: the chevron keeps its column at rest.
    @Test func withNothingLoadingTheChevronShowsAtRest() throws {
        let (header, _) = try Self.header(activity: .idle, unread: .none)
        Self.hover(header, false)
        let chevron = try #require(Self.chevronView(header))
        #expect(!Self.isHidden(chevron, in: header), "the chevron does not show at rest with nothing loading")
    }

    /// On hover the spinner hides at once (no fade beside the controls) and the chevron comes back on its column,
    /// with or without Reduce Motion; when the hover ends the spinner takes the column again.
    @Test(arguments: [false, true])
    func onHoverTheSpinnerHidesForTheChevron(_ reduceMotion: Bool) throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let (header, _) = try Self.header(activity: .working, unread: .none)
        Self.hover(header, false)
        try #require(Self.spinner(header) != nil, "no spinner at rest")
        Self.hover(header, true)
        #expect(Self.spinner(header) == nil, "the spinner shows beside the hover controls")
        let chevron = try #require(Self.chevronView(header))
        #expect(!Self.isHidden(chevron, in: header), "the chevron does not come back on hover")
        let column = SidebarStyle.trailingColumnCenterX(rowWidth: header.bounds.width)
        #expect(abs(chevron.frame.midX - column) <= 0.5, "the chevron is not on the column on hover")
        Self.hover(header, false)
        let spinner = try #require(Self.spinner(header), "the spinner stayed hidden after the hover")
        #expect(abs(spinner.midX - column) <= 0.5, "the spinner came back at \(spinner.midX), not on the column at \(column)")
    }

    /// The opt-in member count reads as a detail: smaller than the name, regular weight, lighter ink.
    @Test func theOptInCountIsSmallRegularAndLighter() throws {
        let design = DesignSettings()
        design.sidebarSections.groupHeaderMemberCount = true
        let (header, sidebar) = try Self.header(activity: .idle, design: design)
        _ = sidebar
        header.updateLayer()
        let count = header.countLabel
        try #require(header.countText == "2")
        let countFont = try #require(count.font), nameFont = header.titleFont
        // 2 pt under the name, never under the type scale's smallest step (compact names already sit on it).
        let small = max(TypeScale.caption, nameFont.pointSize - 2)
        #expect(countFont.pointSize == small, "the count is \(countFont.pointSize) pt beside the \(nameFont.pointSize) pt name, want \(small)")
        let weight = (countFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        #expect(abs(weight - NSFont.Weight.regular.rawValue) < 0.01, "the count's weight is \(weight), not regular")
        let countAlpha = try #require(count.textColor?.alphaComponent), nameAlpha = try #require(header.ink?.alphaComponent)
        #expect(countAlpha < nameAlpha, "the count's ink (alpha \(countAlpha)) is not lighter than the name's (\(nameAlpha))")
    }

    /// A loading header on hover: the chevron, more and + close up with no hole where the spinner was.
    @Test func theButtonsCloseUpOnHover() throws {
        let (header, _) = try Self.header(activity: .working, unread: .none)
        Self.hover(header, true)
        #expect(Self.spinner(header) == nil, "the spinner shows beside the hover controls")
        let chevron = try Self.chevron(header)
        let more = header.moreButton.frame, add = header.addButton.frame
        #expect(chevron.minX - more.maxX <= Self.neighbourGap, "a gap between the more button and the chevron")
        #expect(more.minX - add.maxX <= Self.neighbourGap, "a gap between + and the more button")
        #expect(header.titleFrame.maxX <= add.minX, "the name runs under +")
    }

    /// Nothing loading and no hover: the name may run up to the chevron; no empty slot is kept.
    @Test func withNothingLoadingTheNameRunsToTheChevron() throws {
        let long = "A group whose name is long enough to run past the reserved button slots"
        let (header, _) = try Self.header(activity: .idle, unread: .none, name: long)
        Self.hover(header, false)
        #expect(Self.spinner(header) == nil)
        let chevron = try Self.chevron(header)
        let gap = chevron.minX - header.titleFrame.maxX
        #expect(gap <= Self.neighbourGap + Metrics.space1, "the name stops \(gap) pt before the chevron: an empty gap")
    }
}
