import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// A group or section collapse folds its rows under its header (Dia): the
/// header stays put, its rows slide up beneath it and leave, and an expand
/// slides them back out from under it. Other rows that appear (a new
/// workspace) keep the small drop-in.
@MainActor @Suite struct SidebarCollapseMotionTests {
    let m = SidebarLayoutMetrics.standard

    private func toggled(_ target: CollapseTarget, _ sections: [SidebarSection] = fixture()) -> [SidebarSection] {
        var sections = sections
        _ = SidebarEdits.toggleCollapse(target, in: &sections)
        return sections
    }

    @Test func aCollapsingGroupsRowsSlideUnderItsHeader() throws {
        let old = SidebarLayout.make(sections: fixture(), metrics: m)
        let new = SidebarLayout.make(sections: toggled(.group(g1)), metrics: m)
        let header = try #require(new.row(for: .group(g1)))
        #expect(try #require(old.row(for: .group(g1))).y == header.y, "the header stays put")
        for child in ["g1", "g2", "g3"] {
            let row = try #require(old.row(for: .workspace(id(child))))
            #expect(new.row(for: row.key) == nil)
            #expect(SidebarRowTransition.leaveY(row, from: old, to: new, dropIn: Metrics.space3) == header.y, "\(child)")
        }
    }

    @Test func anExpandingGroupsRowsComeOutFromUnderItsHeader() throws {
        let old = SidebarLayout.make(sections: fixture(), metrics: m)
        let new = SidebarLayout.make(sections: toggled(.group(g2)), metrics: m)
        let header = try #require(new.row(for: .group(g2)))
        for child in ["h1", "h2"] {
            let row = try #require(new.row(for: .workspace(id(child))))
            #expect(old.row(for: row.key) == nil)
            #expect(SidebarRowTransition.appearY(row, from: old, to: new, dropIn: Metrics.space3) == header.y, "\(child)")
        }
    }

    @Test func aCollapsingSectionsRowsSlideUnderItsHeader() throws {
        let old = SidebarLayout.make(sections: fixture(), metrics: m)
        let new = SidebarLayout.make(sections: toggled(.section(local)), metrics: m)
        let header = try #require(new.row(for: .section(local)))
        for child in ["a", "b", "c"] {
            let row = try #require(old.row(for: .workspace(id(child))))
            #expect(SidebarRowTransition.leaveY(row, from: old, to: new, dropIn: Metrics.space3) == header.y, "\(child)")
        }
        let groupHeader = try #require(old.row(for: .group(g1)))
        #expect(SidebarRowTransition.leaveY(groupHeader, from: old, to: new, dropIn: Metrics.space3) == header.y)
    }

    @Test func aNewWorkspaceKeepsTheDropIn() throws {
        var sections = fixture()
        sections[1].nodes.append(.workspace(w("d")))
        let old = SidebarLayout.make(sections: fixture(), metrics: m)
        let new = SidebarLayout.make(sections: sections, metrics: m)
        let row = try #require(new.row(for: .workspace(id("d"))))
        #expect(SidebarRowTransition.appearY(row, from: old, to: new, dropIn: Metrics.space3) == row.y - Metrics.space3)
    }

    /// The rows that come out from under a header are drawn beneath it, so
    /// they never cover it while they move.
    @Test func expandedRowsAreDrawnBeneathTheirHeader() throws {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sidebar.frame = window.contentView.bounds
        window.contentView.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        model.apply(.toggleCollapse(.group(g2)))
        list.reload(animated: true)
        let header = try #require(list.rowViews[.group(g2)])
        let headerIndex = try #require(list.subviews.firstIndex { $0 === header })
        for child in ["h1", "h2"] {
            let view = try #require(list.rowViews[.workspace(id(child))])
            let index = try #require(list.subviews.firstIndex { $0 === view })
            #expect(index < headerIndex, "\(child) is beneath the G2 header")
        }
    }
}
