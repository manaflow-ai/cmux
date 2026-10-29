import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The decided sidebar grid, in points from the sidebar edge. No window or capture is needed:
/// the first test pins the existing layout adapters, and the second lays out each real row view.
/// Keep the expected numbers independent of LayoutGrid so changing a token cannot bless drift.
@MainActor @Suite(.serialized) struct SidebarGridAlignmentTests {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case workspace, item, tab, app, link, sectionHeader, done, showMore, group
    }

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var kind: Kind
        var comfortable: Bool
        var depth: Int
        var marks: Int
        var testDescription: String { "\(kind.rawValue), \(comfortable ? "comfortable" : "compact"), depth \(depth), \(marks) marks" }
    }

    nonisolated static let cases: [Case] = Kind.allCases.flatMap { kind in
        [false, true].flatMap { comfortable in
            (0...2).flatMap { depth in
                [1, 2].map { Case(kind: kind, comfortable: comfortable, depth: depth, marks: $0) }
            }
        }
    }

    private static func withDensity(_ comfortable: Bool, _ body: () throws -> Void) rethrows {
        let before = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = comfortable ? .comfortable : .compact
        defer { DesignSettings.shared.sidebarSections.density = before }
        try body()
    }

    /// Existing APIs only: this test compiles on the pre-fix stack and fails on its old insets,
    /// icon boxes, row heights, nesting step and trailing column rather than on a missing symbol.
    @Test(arguments: cases)
    func columnsAndDensityFollowTheGrid(_ c: Case) {
        Self.withDensity(c.comfortable) {
            let origin = CGFloat(8 + c.depth * 16)
            let width = CGFloat(320) - origin - 8
            let height = Metrics.sidebarRowHeight
            let icon: CGFloat = c.comfortable ? 20 : 16
            #expect(abs(SidebarStyle.horizontalInset - 8) <= 0.5)
            #expect(abs(SidebarStyle.rowEdgeGap - 8) <= 0.5)
            #expect(abs(SidebarStyle.groupGutter - 16) <= 0.5)
            #expect(abs(SidebarStyle.iconBox - icon) <= 0.5)
            #expect(abs(SidebarDensityTokens.rowHeight - height) <= 0.5)
            let headerHeight = Metrics.sidebarHeaderHeight + (c.comfortable ? Metrics.space2 : 0)
            #expect(abs(SidebarDensityTokens.headerHeight - headerHeight) <= 0.5)
            let lead = SidebarStyle.horizontalInset
            let text = c.kind == .sectionHeader ? lead : SidebarStyle.leadingTextX(leading: lead)
            let expectedText = c.kind == .sectionHeader ? CGFloat(16) : (c.comfortable ? 44 : 40)
            #expect(abs(origin + lead - CGFloat(16 + c.depth * 16)) <= 0.5)
            #expect(abs(origin + text - expectedText - CGFloat(c.depth * 16)) <= 0.5)
            // A control's size never changes its center. A second column is one 20 pt pitch in.
            for index in 0..<c.marks {
                let side: CGFloat = index == 0 ? 16 : 12
                let mark = SidebarStyle.trailingColumnFrame(rowWidth: width - CGFloat(index) * 20,
                                                           centerY: height / 2, side: side)
                #expect(abs(origin + mark.midX - (320 - 24 - CGFloat(index) * 20)) <= 0.5)
                #expect(abs(mark.midY - height / 2) <= 0.5)
            }
        }
    }

    /// The same matrix reaches every rendering class. Only workspace and band fixtures show
    /// a leading icon; every iconless fixture uses lead instead of reserving an empty gutter.
    @Test(arguments: cases)
    func actualRowsUseTheTextAndMidLines(_ c: Case) throws {
        try Self.withDensity(c.comfortable) {
            let origin = CGFloat(8 + c.depth * 16)
            let height = c.kind == .sectionHeader ? SidebarDensityTokens.headerHeight : SidebarDensityTokens.rowHeight
            let view = Self.view(c, width: 320 - origin - 8, height: height)
            view.layout()
            #expect(view.window == nil)
            let hasLeadingMark = c.kind == .workspace || c.kind == .item
            let text: CGFloat = hasLeadingMark ? (c.comfortable ? 44 : 40) : 16
            if let workspace = view as? WorkspaceRowView {
                #expect(abs(origin + workspace.title.frame.minX - text - CGFloat(c.depth * 16)) <= 0.5)
                let font = workspace.title.font
                let mid = workspace.title.frame.minY + font.ascender - font.capHeight / 2
                #expect(abs(mid - height / 2) <= 0.5)
                #expect(abs(workspace.icon.frame.midY - height / 2) <= 0.5)
            } else {
                let label = try #require(view.subviews.compactMap { $0 as? ChromeLabel }
                    .first { !$0.isHidden && !$0.stringValue.isEmpty })
                let firstInk = label.frame.minX + label.alignmentRectInsets.left - (c.kind == .item ? 8 : 0)
                #expect(abs(origin + firstInk - text - CGFloat(c.depth * 16)) <= 0.5)
                let font = try #require(label.font)
                let mid = label.frame.minY + label.firstBaselineOffsetFromTop - font.capHeight / 2
                #expect(abs(mid - height / 2) <= 0.5)
            }
        }
    }

    /// Lawrence's iconless-title contract survives the grid: the first ink stays at lead,
    /// with no empty icon gutter, at every depth and with either trailing cluster.
    @Test(arguments: cases.filter { $0.kind == .workspace })
    func iconlessWorkspaceUsesLead(_ c: Case) throws {
        try Self.withDensity(c.comfortable) {
            let origin = CGFloat(8 + c.depth * 16)
            let workspace = try #require(Self.view(c, width: 320 - origin - 8,
                                                  height: SidebarDensityTokens.rowHeight,
                                                  workspaceIcon: false) as? WorkspaceRowView)
            workspace.layout()
            #expect(workspace.icon.frame.width == 0)
            #expect(abs(origin + workspace.title.frame.minX - CGFloat(16 + c.depth * 16)) <= 0.5)
        }
    }

    private static func row(_ key: SidebarRowKey, height: CGFloat) -> SidebarRow {
        SidebarRow(key: key, y: 0, height: height, section: .machine(.local), group: nil,
                   siblingIndex: 0, parentIndex: nil, isLastInGroup: false, isCollapsed: true,
                   childCount: 3, groupColor: nil)
    }

    private static func view(_ c: Case, width: CGFloat, height: CGFloat, workspaceIcon: Bool = true) -> NSView {
        let workspaceID = WorkspaceID("grid-workspace")
        let groupID = GroupID("grid-group")
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let result: NSView
        switch c.kind {
        case .workspace:
            let view = WorkspaceRowView(key: .workspace(workspaceID))
            let workspace = SidebarWorkspace(id: workspaceID, title: "Grid", icon: workspaceIcon ? .emoji("G") : nil, unread: .dot)
            var row = row(view.key, height: height)
            row.content = WorkspaceRowContent(icon: workspace.icon, activity: c.marks == 2 ? .error : .idle)
            view.configure(workspace, row: row, badgeStyle: .trailing)
            result = view
        case .item:
            let view = SidebarItemRowView(frame: frame)
            var info = SidebarItemInfo(title: "Grid", symbol: "square", badge: c.marks == 2 ? 2 : nil)
            info.activity = .error
            view.configure(info, style: .builtIn)
            // Band rows own their outer inset, unlike the other row classes.
            view.frame.size.width += 16
            return view
        case .app, .link:
            let view = SidebarItemListRowView(key: .item("grid-item"))
            let item = SidebarListItem(id: "grid-item", ref: c.kind == .app ? .app("grid/app") : .url("https://example.com"), title: "Grid")
            view.configure(item, favicon: nil, row: row(view.key, height: height))
            result = view
        case .tab:
            let tabID = TabID("grid-tab")
            let view = SidebarTabRowView(key: .tab(workspaceID, tabID))
            let tab = SidebarTab(id: tabID, title: "Grid", isUnread: true)
            view.configure(tab, row: row(view.key, height: height))
            result = view
        case .sectionHeader:
            let view = SectionHeaderRowView(key: .section(.machine(.local)))
            let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Grid", kind: .local)), nodes: [
                .workspace(SidebarWorkspace(id: workspaceID, title: "Member")),
            ])
            view.allowsAdd = c.marks == 2
            view.configure(section, row: row(view.key, height: height))
            result = view
        case .done, .showMore:
            let id = SidebarDoneFoldID(section: .machine(.local), group: nil)
            let view = SidebarDoneFoldRowView(key: c.kind == .done ? .doneFold(id) : .showMore(id))
            view.configure(row(view.key, height: height))
            result = view
        case .group:
            let view = GroupHeaderRowView(key: .group(groupID))
            let group = SidebarGroup(id: groupID, name: "Grid", color: .blue, workspaces: [
                SidebarWorkspace(id: workspaceID, title: "Member"),
            ])
            view.configure(group, row: row(view.key, height: height), animated: false)
            view.isHovered = c.marks == 2
            result = view
        }
        result.frame = frame
        return result
    }
}

extension SidebarGridAlignmentTests {
    @Test(arguments: cases)
    func pureColumnsKeepIconDisclosureTextAndTrailingBoxesOnTheirLines(_ c: Case) {
        let columns = SidebarColumns(rowWidth: 304, comfortable: c.comfortable, depth: c.depth)
        let height: CGFloat = c.comfortable ? 32 : 24
        let icon = columns.iconFrame(height: height)
        #expect(abs(icon.minX - CGFloat(8 + c.depth * 16)) <= 0.5)
        #expect(abs(icon.width - (c.comfortable ? 20 : 16)) <= 0.5)
        #expect(abs(icon.midY - height / 2) <= 0.5)
        #expect(abs(columns.text - CGFloat(c.comfortable ? 36 : 32) - CGFloat(c.depth * 16)) <= 0.5)
        #expect(abs(columns.text(hasLeadingMark: false) - CGFloat(8 + c.depth * 16)) <= 0.5)
        #expect(columns.text(hasLeadingMark: true) == columns.text)
        let disclosure = columns.disclosureFrame(height: height)
        #expect(abs(disclosure.maxX - icon.minX) <= 0.5)
        #expect(disclosure.width == 16)
        #expect(abs(disclosure.midY - height / 2) <= 0.5)
        for index in 0..<c.marks {
            let mark = columns.trailingFrame(index: index, centerY: columns.mid(height: height), side: 12)
            #expect(abs(mark.midX - CGFloat(288 - index * 20)) <= 0.5)
            #expect(abs(mark.midY - height / 2) <= 0.5)
            #expect(columns.textEnd(trailingMarks: c.marks) <= mark.minX - 4)
        }
        #expect(abs(columns.textEnd(trailingMarks: c.marks) - CGFloat(276 - (c.marks - 1) * 20)) <= 0.5)
        let baseline: CGFloat = 12.25, capHeight: CGFloat = 9.5
        let y = columns.textOriginY(centerY: height / 2, baseline: baseline, capHeight: capHeight)
        #expect(abs(y + baseline - capHeight / 2 - height / 2) <= 0.5)
    }

    @Test(arguments: [false, true], [CGFloat(6), 12, 16, 18, 20, 24, 45, 72])
    func aWideBadgeReservesWholePitchesWithoutMovingTheNextMark(comfortable: Bool, width: CGFloat) {
        let columns = SidebarColumns(rowWidth: 304, comfortable: comfortable)
        let badge = columns.trailingFrame(before: columns.trailingEdge, centerY: 14, size: CGSize(width: width, height: 16))
        if width <= 20 {
            #expect(abs(badge.midX - 288) <= 0.5)
        } else {
            #expect(abs(badge.maxX - 296) <= 0.5)
        }
        let edge = columns.trailingEdge(before: badge)
        let next = columns.trailingFrame(before: edge, centerY: 14, size: CGSize(width: 16, height: 12))
        let pitches = (columns.trailingCenter() - next.midX) / 20
        #expect(pitches >= 1)
        #expect(abs(pitches - pitches.rounded()) <= 0.001)
        #expect(next.maxX <= badge.minX - 4 + 0.5)
        #expect(abs(next.midY - badge.midY) <= 0.5)
    }

    @Test(arguments: [false, true], [1, 2])
    func workspaceStatusAndUnreadUseTheFirstTwoColumns(comfortable: Bool, marks: Int) throws {
        try Self.withDensity(comfortable) {
            let c = Case(kind: .workspace, comfortable: comfortable, depth: 0, marks: marks)
            let height = SidebarDensityTokens.rowHeight
            let workspace = try #require(Self.view(c, width: 304, height: height) as? WorkspaceRowView)
            workspace.layout()
            let unread = try #require(workspace.subviews.compactMap { $0 as? UnreadBadgeView }.first { $0.state.isUnread })
            #expect(abs(unread.frame.midX - CGFloat(marks == 1 ? 288 : 268)) <= 0.5)
            #expect(abs(unread.frame.midY - height / 2) <= 0.5)
            if marks == 2 {
                let status = try #require(workspace.subviews.compactMap { $0 as? StatusIndicatorView }.first { $0.showsGlyph })
                #expect(abs(status.frame.midX - 288) <= 0.5)
                #expect(abs(status.frame.midY - height / 2) <= 0.5)
                #expect(unread.frame.maxX <= status.frame.minX)
            }
        }
    }

    @Test(arguments: [false, true], [1, 2])
    func sectionFoldAndAddUseTheFirstTwoColumns(comfortable: Bool, marks: Int) throws {
        try Self.withDensity(comfortable) {
            let c = Case(kind: .sectionHeader, comfortable: comfortable, depth: 0, marks: marks)
            let height = SidebarDensityTokens.headerHeight
            let section = try #require(Self.view(c, width: 304, height: height) as? SectionHeaderRowView)
            section.layout()
            let fold = try #require(section.subviews.compactMap { $0 as? DecorativeImageView }.first { !$0.isHidden })
            #expect(abs(fold.frame.midX - 288) <= 0.5)
            #expect(abs(fold.frame.midY - height / 2) <= 0.5)
            #expect(section.addButton.isHidden == (marks == 1))
            if marks == 2 {
                #expect(abs(section.addButton.frame.midX - 268) <= 0.5)
                #expect(abs(section.addButton.frame.midY - height / 2) <= 0.5)
                #expect(section.addButton.frame.maxX <= fold.frame.minX)
            }
        }
    }

    /// Exercise the list's real coordinate conversion as well as local row layout. Structural
    /// group depth counts the containing group; visual depth starts with its first nested group.
    @Test(arguments: [false, true], [0, 1, 2])
    func listFramesApplyNestingWithoutMovingTheTrailingLine(comfortable: Bool, depth: Int) {
        Self.withDensity(comfortable) {
            let list = SidebarListView(model: SidebarModel(sections: []))
            list.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
            #expect(list.window == nil)
            let height = SidebarDensityTokens.rowHeight
            let group = GroupID("grid-nesting")
            let keys: [SidebarRowKey] = [
                .workspace(WorkspaceID("grid-nesting")), .tab(WorkspaceID("grid-nesting"), TabID("grid-nesting")),
                .item("grid-nesting"), .doneFold(SidebarDoneFoldID(section: .machine(.local), group: group)),
                .showMore(SidebarDoneFoldID(section: .machine(.local), group: group)), .group(group),
            ]
            for key in keys {
                var row = Self.row(key, height: height)
                row.group = group
                if case .group = key { row.depth = depth } else { row.depth = depth + 1 }
                let frame = list.frame(for: row)
                let reach = list.railReach(for: row)
                #expect(abs(frame.minX + reach - CGFloat(8 + depth * 16)) <= 0.5)
                #expect(abs(frame.maxX - 312) <= 0.5)
                let columns = SidebarColumns(rowWidth: frame.width, comfortable: comfortable, leadingOffset: reach)
                #expect(abs(frame.minX + columns.lead - CGFloat(16 + depth * 16)) <= 0.5)
                #expect(abs(frame.minX + columns.trailingCenter() - 296) <= 0.5)
            }
        }
    }
}
