import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Workspace groups, option B "Color label and band" (Lawrence 2026-10-07:
/// "i like Option B"; spec WORKSPACE-GROUPS-OPTION-A amendment 1): the group
/// name sits in a colored label (the tab-group chip: GroupColor.fill, a
/// neutral chip without a color), and the members carry one continuous band
/// in the group color under the header's caret, indented past it.
@MainActor @Suite struct GroupLabelBandTests {
    @Test func theNameSitsInAColoredLabel() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        let chip = header.labelFrame
        #expect(chip.width > 0 && chip.height > 0)
        #expect(chip.minX > header.disclosureFrame.minX, "the caret leads (S1)")
        #expect(chip.contains(NSPoint(x: header.titleFrame.midX, y: header.titleFrame.midY)), "the name is inside the label")
        #expect(header.labelFill != nil, "a colored group's label is filled")
    }

    @Test func aGroupWithoutAColorGetsANeutralLabel() throws {
        var sections = fixture()
        sections[1].nodes[1] = .group(SidebarGroup(id: g1, name: "G1", color: .grey, workspaces: [w("g1")]))
        let h = MinimalChromeTests.Harness(sections: sections)
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        #expect(header.labelFrame.width > 0)
        #expect(header.labelFill != nil, "an uncolored group still reads as a group")
    }

    @Test func membersIndentPastTheCaretOnOneContinuousBand() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        let first = try #require(h.sidebar.list.rowViews[.workspace(id("g1"))] as? WorkspaceRowView)
        let second = try #require(h.sidebar.list.rowViews[.workspace(id("g2"))] as? WorkspaceRowView)
        let loose = try #require(h.sidebar.list.rowViews[.workspace(id("b"))] as? WorkspaceRowView)
        [header, first, second, loose].forEach { $0.layoutSubtreeIfNeeded() }
        #expect(loose.titleFrame.minX == SidebarStyle.titleLeading, "a loose row keeps the inset")
        #expect(first.titleFrame.minX > header.disclosureFrame.maxX, "member \(first.titleFrame.minX) caret \(header.disclosureFrame.maxX)")
        // The band fills each member row top to bottom, so adjacent rows join.
        for row in [first, second] {
            let band = row.groupBandFrame
            #expect(band.width >= 2, "a visible band")
            #expect(band.minY <= 0 && band.maxY >= row.bounds.height, "full height \(band) in \(row.bounds)")
            #expect(band.midX < first.titleFrame.minX)
        }
        #expect(loose.groupBandFrame == .zero || loose.isGroupBandHidden)
    }

    @Test func aNameThatFitsIsNeverCutShort() throws {
        var sections = fixture()
        sections[1].nodes[1] = .group(SidebarGroup(id: g1, name: "New Group", color: .blue, workspaces: [w("g1")]))
        let h = MinimalChromeTests.Harness(sections: sections)
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        #expect(header.titleFrame.width >= header.titleIntrinsicWidth, "\(header.titleFrame.width) < \(header.titleIntrinsicWidth): the live capture showed “New Gro…”")
    }
}
