import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Testing

/// Lawrence 2026-11-05: "invariant: groups must always have a visible bg color". The real group header, in a dark, a
/// light and a wallpaper room, for a group with no color and for every palette color, collapsed and open, at rest and
/// hovered: its bar as painted over the sidebar keeps at least 1.2:1 against the sidebar. Before the fix a group with
/// no color (the default for every new group since Leo 2026-10-31) painted no bar at all: 1:1, an invisible group.
@MainActor @Suite(.serialized) struct GroupHeaderAlwaysVisibleTests {
    static let minimum = 1.2

    static func rgba(_ color: CGColor?) -> ThemeRGB {
        guard let ns = color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) else { return ThemeRGB(red: 0, green: 0, blue: 0, alpha: 0) }
        return ThemeRGB(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }

    @Test func everyGroupHeaderDrawsAVisibleBackground() throws {
        var failures: [String] = []
        let tints = [GroupTint.none] + GroupColor.allCases.map { GroupTint.palette($0) }
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let ground = scope.tokens.sidebarBackground.withAlpha(1)
            for tint in tints {
                for collapsed in [false, true] {
                    for hovered in [false, true] {
                        let id = GroupID("grp_visible")
                        let header = GroupHeaderRowView(key: .group(id))
                        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                        scope.root(header)
                        let group = CmuxNextSidebar.SidebarGroup(id: id, name: "group", custom: tint.wire, workspaces: [])
                        let row = SidebarRow(key: .group(id), y: 0, height: 24, section: .pinned, group: id, siblingIndex: 0,
                                             parentIndex: nil, isLastInGroup: false, isCollapsed: collapsed, childCount: 0, groupColor: nil)
                        header.configure(group, row: row, animated: false)
                        header.isHovered = hovered
                        header.layoutSubtreeIfNeeded()
                        header.updateLayer()
                        let label = "\(name) \(tint.wire)\(collapsed ? " collapsed" : "")\(hovered ? " hovered" : "")"
                        guard !header.pill.isHidden else {
                            failures.append("\(label): no background")
                            continue
                        }
                        let shown = Self.rgba(header.pill.backgroundColor).composited(over: ground)
                        let contrast = shown.contrast(with: ground)
                        if contrast < Self.minimum - 0.005 { failures.append(String(format: "%@: %.3f:1", label, contrast)) }
                    }
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) invisible group backgrounds:\n" + failures.joined(separator: "\n")))
    }

    /// Switching `sidebar.groupHeader.background` redraws the headers already on screen.
    @Test func changingTheBackgroundStyleRedrawsTheList() {
        var before = SidebarSectionsPreferences()
        before.groupHeaderBackground = .solid
        var after = before
        after.groupHeaderBackground = .glass
        #expect(after.changesList(from: before))
        #expect(!before.changesList(from: before))
    }
}
