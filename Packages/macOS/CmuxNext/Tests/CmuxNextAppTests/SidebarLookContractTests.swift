import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar look contract (plans/cmux-next/sidebar-owner.md, "Target look"): the measured geometry of
/// the real ``SidebarListView`` at every density, Minimal Mode and sidebar width. Each check names the
/// user's words that set it. Changing one of these is a look change: it needs the user's ask, the owner
/// note and a `Sidebar-Look:` trailer (scripts/cmux-next/prepush-gate.py), never an edit of this file alone.
///
/// The rail's left edge on its header bar is held by ``SidebarGroupRailAlignmentTests``; header and row
/// heights by the group header height suites. This suite holds what those do not: where text starts,
/// where rows end, and what the hover close is.
@MainActor @Suite(.serialized) struct SidebarLookContractTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var width: CGFloat
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/\(Int(width))pt" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [SidebarMinimalMode.off, .both].flatMap { minimal in [200, 260, 360].map { Case(density: density, minimal: minimal, width: $0) } }
    }

    static let loose = WorkspaceID("c-loose"), icon = WorkspaceID("c-icon"), member = WorkspaceID("c-member")
    static let nested = WorkspaceID("c-nested"), group = GroupID("c-group"), sub = GroupID("c-sub")

    static func sections() -> [SidebarSection] {
        var subgroup = SidebarGroup(id: sub, name: "Perf", color: .yellow, workspaces: [SidebarWorkspace(id: nested, title: "Tab switch")])
        subgroup.parent = group
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: loose, title: "Slimmer CEF bundle")),
            .workspace(SidebarWorkspace(id: icon, title: "Ship it", icon: .emoji("🚀"))),
            .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, workspaces: [SidebarWorkspace(id: member, title: "Reopen closes all")])),
            .group(subgroup),
        ])]
    }

    /// The list in a window at `width`, every row realized and laid out.
    static func list(width: CGFloat) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        window.contentView = root
        let list = SidebarListView(model: SidebarModel(sections: sections()))
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (list, window)
    }

    static func row(_ list: SidebarListView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(list.rowViews[.workspace(id)] as? WorkspaceRowView, "\(id.rawValue) has no row")
    }

    /// Where `row`'s title glyphs start, in list points.
    static func textX(_ list: SidebarListView, _ row: WorkspaceRowView) -> CGFloat {
        list.convert(NSPoint(x: row.title.frame.minX, y: 0), from: row).x
    }

    /// Lawrence 2026-10-23: "text needs to be as left as possible (how it originally was)". A row with no icon
    /// starts its title at the row's inset; a top-level group's member at the same x as an ungrouped row (#23975).
    @Test(arguments: cases)
    func titlesStartAsFarLeftAsTheRowAllows(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let loose = try Self.row(list, Self.loose), member = try Self.row(list, Self.member)
            let looseX = Self.textX(list, loose)
            #expect(looseX == list.frame(for: try #require(list.displayed.row(for: .workspace(Self.loose)))).minX + SidebarStyle.horizontalInset,
                    "\(c.testDescription): an ungrouped title at \(looseX)")
            #expect(Self.textX(list, member) == looseX, "\(c.testDescription): member \(Self.textX(list, member)), ungrouped \(looseX)")
            // An icon sits where text would start; the title follows it, never under it.
            let iconRow = try Self.row(list, Self.icon)
            #expect(list.convert(iconRow.icon.frame, from: iconRow).minX == looseX, "\(c.testDescription): icon not at the text column")
            #expect(iconRow.title.frame.minX >= iconRow.icon.frame.minX + SidebarStyle.kindGlyphSize, "\(c.testDescription): title under the icon")
        }
    }

    /// A nested group's rows step in by exactly one indent step per level, and its text keeps the inset inside its row.
    @Test(arguments: cases)
    func aNestedMemberStepsInOneIndent(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let nested = Self.textX(list, try Self.row(list, Self.nested)), member = Self.textX(list, try Self.row(list, Self.member))
            #expect(nested - member == list.indent.step, "\(c.testDescription): nested text \(nested), member \(member)")
        }
    }

    /// Leo 2026-10-21 (#23783, kept by the owner): rows run to the list's inset on the right, every kind alike.
    @Test(arguments: cases)
    func rowsEndAtTheListsInset(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let end = list.bounds.width - list.inset - SidebarStyle.rowTrailingTrim
            for row in list.displayed.rows {
                switch row.key {
                case .workspace, .group: #expect(list.frame(for: row).maxX == end, "\(c.testDescription): \(row.key) ends at \(list.frame(for: row).maxX), not \(end)")
                default: continue
                }
            }
        }
    }

    /// Lawrence 2026-10-23: "need to revert styling back to original, for the X button". The hover close is the
    /// row's own x button at the end of the title's line, inside the row's inset, never a corner fold.
    @Test(arguments: SidebarDensity.allCases)
    func theHoverCloseIsTheRowsTrailingX(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (list, window) = Self.list(width: 260)
            defer { window.close() }
            for id in [Self.loose, Self.member, Self.nested] {
                let row = try Self.row(list, id)
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                let close: NSView = row.closeButton
                #expect(!close.isHidden, "\(density.rawValue) \(id.rawValue): no close on hover")
                #expect(close.frame.size == NSSize(width: SidebarStyle.controlSize, height: SidebarStyle.controlSize))
                #expect(abs(close.frame.midY - row.title.frame.midY) < 1, "\(density.rawValue) \(id.rawValue): close off the title's line")
                #expect(close.frame.maxX <= row.bounds.width - SidebarStyle.horizontalInset + 0.5,
                        "\(density.rawValue) \(id.rawValue): close ends \(row.bounds.width - close.frame.maxX) pt in")
                #expect(close.frame.minY >= 0 && close.frame.maxY <= row.bounds.height, "\(density.rawValue) \(id.rawValue): close outside its row")
            }
        }
    }
}
