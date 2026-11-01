import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21 (sidebar organization, item A): every row carries its pull request badge, not only
/// with the session tree on. The tree's nesting, guide line and keycaps stay opt-in
/// (`sidebar.sessionTree`); the badge follows `sidebar.pullRequestBadges` (on by default).
/// Leo 2026-10-21, "REMOVE PR INDICATORS BY DEFAULT": every pull request mark on a row follows
/// `sidebar.workspaceRow.pullRequest`, off by default.
@MainActor @Suite(.serialized) struct SidebarPullRequestBadgeTests {
    private static let chief = WorkspaceID("ws-chief")
    private static let other = WorkspaceID("ws-other")
    private static let lane = WorkspaceID("ws-lane")
    private static let badge = SidebarPullRequestBadge(count: 2, status: .attention)

    /// Settings with the Pull Request row element on (`sidebar.workspaceRow.pullRequest`).
    static func showingPullRequests() -> DesignSettings {
        let design = DesignSettings()
        design.sidebarSections.workspaceRow.base.shown.insert(.pullRequest)
        return design
    }

    private static let sections = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: chief, title: "chief")),
            .workspace(SidebarWorkspace(id: other, title: "other")),
            .workspace(SidebarWorkspace(id: lane, title: "lane")),
        ]),
    ]

    @Test func withTheTreeOffTheFeedPublishesBadgesButNoTree() {
        let tree = SidebarSessionTree()
        let state = SidebarSessionTreeState(parents: [Self.lane: Self.chief], pullRequests: [Self.lane: Self.badge])
        SidebarSessionTreeFeed.publish(SidebarSessionTreeFeed.Pass(state: state, asks: [], showsTree: false), to: tree)
        #expect(tree.state == nil, "no nesting, guide lines or keycaps while the tree is off")
        #expect(tree.pullRequests == [Self.lane: Self.badge])

        SidebarSessionTreeFeed.publish(SidebarSessionTreeFeed.Pass(state: state, asks: [], showsTree: true), to: tree)
        #expect(tree.state == state)
        SidebarSessionTreeFeed.publish(nil, to: tree)
        #expect(tree.state == nil)
        #expect(tree.pullRequests.isEmpty)
    }

    @Test func aRowDrawsItsBadgeWithTheTreeOffInManualOrder() throws {
        SidebarSessionTree.shared.pullRequests = [Self.lane: Self.badge]
        defer { SidebarSessionTree.shared.pullRequests = [:] }
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections), design: Self.showingPullRequests())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow() // the design's row settings reach the model
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let parent = try #require(sidebar.list.rowViews[.workspace(Self.chief)] as? WorkspaceRowView)
        let child = try #require(sidebar.list.rowViews[.workspace(Self.lane)] as? WorkspaceRowView)
        #expect(!child.pullRequests.isHidden)
        #expect(child.pullRequests.badge == Self.badge)
        #expect(parent.pullRequests.isHidden)
        #expect(child.treeLine.isHidden, "no nesting without the tree")
        #expect(child.keycap.isHidden && parent.keycap.isHidden, "no keycaps without the tree")
    }

    @Test func aBadgeThatArrivesLaterIsDrawn() throws {
        defer { SidebarSessionTree.shared.pullRequests = [:] }
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections), design: Self.showingPullRequests())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        let row = { try #require(sidebar.list.rowViews[.workspace(Self.lane)] as? WorkspaceRowView) }
        #expect(try row().pullRequests.isHidden)

        SidebarSessionTree.shared.pullRequests = [Self.lane: Self.badge]
        sidebar.renderNow()
        #expect(try row().pullRequests.badge == Self.badge)

        SidebarSessionTree.shared.pullRequests = [:]
        sidebar.renderNow()
        #expect(try row().pullRequests.isHidden)
    }

    @Test func layoutOptionsCarryTheBadgeWithoutTheTree() {
        var options = SidebarLayoutOptions()
        options.workspaceRow.base.shown.insert(.pullRequest)
        options.pullRequests = [Self.lane: Self.badge]
        let rows = SidebarLayout.make(sections: Self.sections, metrics: .standard, options: options).rows
        let drawn = rows.compactMap { row -> (WorkspaceID, SidebarPullRequestBadge?, Int)? in
            if case let .workspace(id) = row.key { (id, row.content?.pullRequests, row.content?.treeDepth ?? 0) } else { nil }
        }
        #expect(drawn.map(\.0) == [Self.chief, Self.other, Self.lane], "manual order")
        #expect(drawn.map(\.1) == [nil, nil, Self.badge])
        #expect(drawn.map(\.2) == [0, 0, 0])
    }

    // MARK: Off by default (Leo 2026-10-21, "REMOVE PR INDICATORS BY DEFAULT")

    /// The lane's row has both kinds of pull request mark: a hook's text and the read badge.
    private static let reportingSections = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: chief, title: "chief")),
            .workspace(SidebarWorkspace(id: lane, title: "lane", pullRequest: "#12 checks pass")),
        ]),
    ]

    @Test func byDefaultARowWithPullRequestsDrawsNoPullRequestIndicator() throws {
        SidebarSessionTree.shared.pullRequests = [Self.lane: Self.badge]
        defer { SidebarSessionTree.shared.pullRequests = [:] }
        let design = DesignSettings()
        #expect(!design.sidebarSections.workspaceRow.base.shows(.pullRequest), "the Pull Request element is off by default")
        let sidebar = SidebarView(model: SidebarModel(sections: Self.reportingSections), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        let row = { () throws -> WorkspaceRowView in
            let row = try #require(sidebar.list.rowViews[.workspace(Self.lane)] as? WorkspaceRowView)
            row.layoutSubtreeIfNeeded()
            return row
        }
        #expect(try row().pullRequests.isHidden, "no glyph and count")
        #expect(try row().pullRequests.badge == nil)
        #expect(try row().prBadge.isHidden, "no hook text")

        design.sidebarSections.workspaceRow.base.shown.insert(.pullRequest)
        sidebar.renderNow()
        #expect(try !row().pullRequests.isHidden)
        #expect(try row().pullRequests.badge == Self.badge)
        #expect(try !row().prBadge.isHidden)
    }

    @Test func theRowElementGatesEveryLayoutsPullRequestMarks() {
        let ws = SidebarWorkspace(id: Self.lane, title: "lane", pullRequest: "#12 checks pass")
        var options = SidebarLayoutOptions()
        options.pullRequests = [Self.lane: Self.badge]
        options.sessionTree = SidebarSessionTreeState(pullRequests: [Self.lane: Self.badge])
        let off = options.rowContent(ws, machine: nil)
        #expect(off.pullRequests == nil, "the tree's badge too")
        #expect(off.badge == nil)
        options.expanded = true
        #expect(options.rowContent(ws, machine: nil).meta == nil, "an expanded row's third line leaves it out")

        options.workspaceRow.base.shown.insert(.pullRequest)
        #expect(options.rowContent(ws, machine: nil).meta == "#12 checks pass")
        options.expanded = false
        let on = options.rowContent(ws, machine: nil)
        #expect(on.pullRequests == Self.badge)
        #expect(on.badge == "#12 checks pass")

        // A kind's override turns it off for that kind only.
        options.workspaceRow.overrides[.terminal] = WorkspaceRowOverride(elements: [.pullRequest: false])
        #expect(options.rowContent(ws, machine: nil).pullRequests == nil)
    }

    // MARK: Quiet marks (Leo 2026-10-21, "did we remove the pr things by default and also redesign tehm to be better")

    @Test func theBadgeIsQuietUnlessItsChecksFail() {
        #expect(SidebarPullRequestBadgeView.color(.failing) == Palette.danger, "failing checks need the person")
        for status in [SidebarPullRequestBadge.Status.passing, .attention, .merged] {
            #expect(SidebarPullRequestBadgeView.color(status) == Palette.textSecondary, "\(status) stays quiet: no wall of purple")
        }
    }

    @Test func onePullRequestDrawsTheGlyphAloneAndSeveralDrawTheCount() {
        let glyph = ceil(SidebarStyle.subtitleFont.pointSize)
        let view = SidebarPullRequestBadgeView()
        view.configure(SidebarPullRequestBadge(count: 1, status: .merged))
        #expect(view.intrinsicContentSize.width == glyph, "the glyph's width only, the row's other icons' size")

        // A row view is reused: one, several, one, several.
        for (count, drawsCount) in [(2, true), (1, false), (3, true)] {
            view.configure(SidebarPullRequestBadge(count: count, status: .failing))
            let size = view.intrinsicContentSize
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let label = view.subviews.compactMap { $0 as? ChromeLabel }.first
            #expect((size.width > glyph) == drawsCount, "\(count) pull requests: the count shows only above one")
            #expect((label?.isHidden == false && (label?.frame.width ?? 0) > 0) == drawsCount, "its label is laid out only then")
        }
    }

    @Test func theBadgeReadsRunOnlyWhileSomeRowShowsPullRequests() {
        var sections = SidebarSectionsPreferences.defaults
        #expect(!SidebarSessionTreeFeed.readsBadges(sections), "no GitHub reads for badges nobody sees")
        sections.workspaceRow.overrides[.agent] = WorkspaceRowOverride(elements: [.pullRequest: true])
        #expect(SidebarSessionTreeFeed.readsBadges(sections))
        sections.workspaceRow = .defaults
        sections.workspaceRow.base.shown.insert(.pullRequest)
        #expect(SidebarSessionTreeFeed.readsBadges(sections))
        // On in the base set but off for every kind: no row shows one.
        for kind in WorkspaceRowKind.allCases {
            sections.workspaceRow.overrides[kind] = WorkspaceRowOverride(elements: [.pullRequest: false])
        }
        #expect(!SidebarSessionTreeFeed.readsBadges(sections))
    }
}
