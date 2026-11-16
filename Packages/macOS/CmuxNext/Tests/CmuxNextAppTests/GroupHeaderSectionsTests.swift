import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Testing

/// `sidebar.groupHeader.background` Sections (Leo 2026-11-05, of chat apps' sidebars: "they have these sections ...
/// maybe we can also have an option to have that"): a group draws as a plain section heading. The real header, for a
/// group with no color and every palette color, in a dark, a light and a wallpaper room: no fill, rim or dot at rest,
/// its name in the theme's quiet ink; the row's own fill under the pointer; its members' line draws nothing. The
/// default stays cmux's glass group (`GroupHeaderAlwaysVisibleTests`).
@MainActor @Suite(.serialized) struct GroupHeaderSectionsTests {
    static func header(_ tint: GroupTint, in scope: ThemeScope, hovered: Bool) -> GroupHeaderRowView {
        let id = GroupID("grp_section")
        let header = GroupHeaderRowView(key: .group(id))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        scope.root(header)
        let group = CmuxNextSidebar.SidebarGroup(id: id, name: "group", custom: tint.wire, workspaces: [])
        let row = SidebarRow(key: .group(id), y: 0, height: 24, section: .pinned, group: id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 2, groupColor: nil)
        header.configure(group, row: row, details: GroupHeaderDetails(background: .sections), animated: false)
        header.isHovered = hovered
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header
    }

    @Test func sectionsDrawsAPlainHeadingInEveryRoom() throws {
        var failures: [String] = []
        let tints = [GroupTint.none] + GroupColor.allCases.map { GroupTint.palette($0) }
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let quiet = scope.tokens.textSecondary
            for tint in tints {
                let label = "\(name) \(tint.wire)"
                let header = Self.header(tint, in: scope, hovered: false)
                let fill = GroupHeaderAlwaysVisibleTests.rgba(header.pill.backgroundColor)
                if fill.alpha > 0.001 { failures.append("\(label): a fill \(fill)") }
                if !header.rim.isHidden { failures.append("\(label): a rim") }
                if !header.dot.isHidden { failures.append("\(label): a dot") }
                if header.debugFill { failures.append("\(label): a row fill at rest") }
                let ink = try GroupPaletteDefaultTests.rgb(header.ink?.cgColor)
                if !GroupPaletteDefaultTests.same(ink, quiet) { failures.append("\(label): ink \(ink), want the quiet \(quiet)") }
                if !Self.header(tint, in: scope, hovered: true).debugFill { failures.append("\(label): no fill under the pointer") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) section headings off:\n" + failures.joined(separator: "\n")))
    }

    @Test func sectionsMembersDrawNoLineOrBlock() throws {
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            for (tint, block) in [(GroupTint.palette(.blue), false), (GroupTint.none, true)] {
                let line = GroupLineView()
                line.frame = NSRect(x: 0, y: 0, width: block ? 240 : 2, height: 48)
                scope.root(line)
                line.color = tint
                line.isBlock = block
                line.background = .sections
                line.updateLayer()
                #expect(line.railShape.fillColor == nil, "\(name) \(tint.wire): a rail")
                #expect(line.layer?.backgroundColor == nil, "\(name) \(tint.wire): a block")
                #expect(line.rim.isHidden, "\(name) \(tint.wire): a rim")
            }
        }
    }

    @Test func sectionsIsAnOptionNotTheDefault() {
        #expect(SidebarSectionsPreferences().groupHeaderBackground == .auto)
        #expect(!SidebarGroupBackgroundStyle.sections.drawsBackground)
        #expect(!SidebarGroupBackgroundStyle.sections.drawsGlass(appLooksGlassy: true))
        #expect(SidebarGroupBackgroundStyle.allCases.filter { !$0.drawsBackground } == [.sections])
        var before = SidebarSectionsPreferences()
        before.groupHeaderBackground = .auto
        var after = before
        after.groupHeaderBackground = .sections
        #expect(after.changesList(from: before), "switching to Sections redraws the headers on screen")
    }
}
