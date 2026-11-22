import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// A workspace name too long for its row scrolls while the pointer rests
/// on the row and stops at once when it leaves (nxdog13).
@MainActor @Suite struct WorkspaceRowMarqueeTests {
    static let long = "A workspace name much too long to fit in the sidebar row at its default width"

    private func row(title: String, policy: MotionPolicy) throws -> (MinimalChromeTests.Harness, WorkspaceRowView) {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(id: id("a"), title: title))
        let h = MinimalChromeTests.Harness(sections: sections)
        let row = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        row.title.motionPolicy = { policy }
        row.layoutSubtreeIfNeeded()
        return (h, row)
    }

    @Test func hoverStartsTheMarqueeOnAClippedNameAndLeavingStopsIt() throws {
        let (h, row) = try row(title: Self.long, policy: MotionPolicy(speed: .fast, reduceMotion: false))
        _ = h
        #expect(row.title.isTruncated)
        row.isHovered = true
        #expect(row.title.isMarqueeActive)
        #expect(row.toolTip == nil)
        row.isHovered = false
        #expect(!row.title.isMarqueeActive)
    }

    @Test func aNameThatFitsNeverScrolls() throws {
        let (h, row) = try row(title: "short", policy: MotionPolicy(speed: .fast, reduceMotion: false))
        _ = h
        row.isHovered = true
        #expect(!row.title.isTruncated)
        #expect(!row.title.isMarqueeActive)
        #expect(row.toolTip == nil)
    }

    /// Under Reduce Motion no marquee runs and no tooltip shows: the
    /// workspace hover card (the one card) carries the whole name.
    @Test func reduceMotionShowsNoMarqueeAndNoSecondPopover() throws {
        let (h, row) = try row(title: Self.long, policy: MotionPolicy(speed: .fast, reduceMotion: true))
        _ = h
        row.isHovered = true
        #expect(!row.title.isMarqueeActive)
        #expect(row.toolTip == nil)
    }

    @Test func theTitleFadesInsteadOfEndingInAnEllipsis() throws {
        let (h, row) = try row(title: Self.long, policy: MotionPolicy(speed: .fast, reduceMotion: false))
        _ = h
        #expect(row.title.stringValue == Self.long, "the whole name is drawn; its end is faded out")
        // No default icon: the title starts at the title leading inset.
        #expect(row.titleFrame.minX == SidebarStyle.titleLeading)
    }
}
