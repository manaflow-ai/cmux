import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Workspace groups as Chrome tab group chips (cx-rcby, Lawrence 2026-10-08,
/// after option B of 2026-10-07): the group name sits in a pill chip filled
/// with the group's theme color (neutral without one) that ends in the
/// collapse chevron, and the members carry one thin continuous bar in the
/// group color under the chip's start, indented past it.
@MainActor @Suite struct GroupLabelBandTests {
    @Test func theNameSitsInAColoredLabel() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        let chip = header.labelFrame
        #expect(chip.width > 0 && chip.height > 0)
        #expect(chip.contains(NSPoint(x: header.disclosureFrame.midX, y: header.disclosureFrame.midY)), "the chevron ends the chip")
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
        #expect(first.titleFrame.minX > first.groupBandFrame.maxX, "member \(first.titleFrame.minX) bar \(first.groupBandFrame.maxX)")
        #expect(first.groupBandFrame.minX >= header.labelFrame.minX, "the bar starts under the chip")
        // The band fills each member row top to bottom, so adjacent rows join.
        for row in [first, second] {
            let band = row.groupBandFrame
            #expect(band.width >= 2 && band.width <= 3, "a thin visible bar")
            #expect(band.minY <= 0 && band.maxY >= row.bounds.height, "full height \(band) in \(row.bounds)")
            #expect(band.midX < first.titleFrame.minX)
        }
        #expect(loose.groupBandFrame == .zero || loose.isGroupBandHidden)
    }

    @Test func aGroupIconLeadsInsideTheLabel() throws {
        var plainSections = fixture()
        plainSections[1].nodes[1] = .group(SidebarGroup(id: g1, name: "Work", color: .blue, workspaces: [w("g1")]))
        let plain = MinimalChromeTests.Harness(sections: plainSections)
        let plainHeader = try #require(plain.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        plainHeader.layoutSubtreeIfNeeded()
        #expect(plainHeader.glyph.isHidden, "no icon, no glyph")

        var sections = fixture()
        sections[1].nodes[1] = .group(SidebarGroup(id: g1, name: "Work", color: .blue, icon: .emoji("🚀"), workspaces: [w("g1")]))
        let h = MinimalChromeTests.Harness(sections: sections)
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        #expect(!header.glyph.isHidden)
        #expect(header.glyph.emojiText == "🚀")
        #expect(header.labelFrame.contains(NSPoint(x: header.glyph.frame.midX, y: header.glyph.frame.midY)), "the icon is inside the label")
        #expect(header.glyph.frame.maxX <= header.titleFrame.minX, "the icon leads the name")
        #expect(header.titleFrame.minX > plainHeader.titleFrame.minX, "the name moves past the icon")
        #expect(header.titleFrame.width >= header.titleIntrinsicWidth, "the name still draws whole")
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
