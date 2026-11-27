import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// Leo, 2026-11-22: "if we're willing to push in directions, we might as well push harder into what we believe", of
/// the sidebar's plain folders. Three more opt-in `sidebar.groupHeader.background` looks, none the default: `chip`
/// (Chromium's tab group: a slim colored chip, a colored rail, no indent), `tree` (the folder and its indent with a
/// thin guide line under the glyph) and `card` (one tinted rounded card around the whole group).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupLooksTests {
    static let group = GroupID("g-look")
    static let looseID = WorkspaceID("ws-loose")
    static let memberID = WorkspaceID("ws-member")
    static let otherID = WorkspaceID("ws-other")

    /// A sidebar with one loose workspace and an open group of two, in `style`.
    static func sidebar(_ style: SidebarGroupBackgroundStyle, tint: GroupTint = .palette(.blue), collapsed: Bool = false) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let folder = SidebarGroup(id: group, name: "Backend", custom: tint.wire, isCollapsed: collapsed, workspaces: [
            SidebarWorkspace(id: memberID, title: "api server"),
            SidebarWorkspace(id: otherID, title: "web app"),
        ])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: looseID, title: "scratch")), .group(folder)]),
        ], activeWorkspaceID: looseID)
        var preferences = SidebarSectionsPreferences()
        preferences.groupHeaderBackground = style
        model.applyListPreferences(preferences)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.model.applyListPreferences(preferences)
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    static func header(_ style: SidebarGroupBackgroundStyle, _ tint: GroupTint, in scope: ThemeScope) -> GroupHeaderRowView {
        let id = GroupID("grp_look")
        let header = GroupHeaderRowView(key: .group(id))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        scope.root(header)
        let group = CmuxNextSidebar.SidebarGroup(id: id, name: "Backend", custom: tint.wire, workspaces: [])
        let row = SidebarRow(key: .group(id), y: 0, height: 24, section: .pinned, group: id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 2, groupColor: nil)
        header.configure(group, row: row, details: GroupHeaderDetails(background: style), animated: false)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header
    }

    static func lineView(_ style: SidebarGroupBackgroundStyle, _ tint: GroupTint, block: Bool, in scope: ThemeScope) -> GroupLineView {
        let line = GroupLineView()
        line.frame = NSRect(x: 0, y: 0, width: block ? 240 : 1, height: 72)
        scope.root(line)
        line.color = tint
        line.isBlock = block
        line.background = style
        line.updateLayer()
        return line
    }

    static let tints = [GroupTint.none, GroupTint.palette(.blue), GroupTint.palette(.red), GroupTint.custom(ThemeRGB(hex: 0x336699))]

    // MARK: the setting

    /// The alternative group looks are opt-in.
    @Test func theLooksAreOptInAndAutomaticIsTheDefault() {
        #expect(SidebarSectionsPreferences().groupHeaderBackground == .auto)
        for raw in ["chip", "tree", "card"] { #expect(SidebarGroupBackgroundStyle(rawValue: raw) != nil, "\(raw) is no value") }
        #expect(SidebarGroupBackgroundStyle.allCases.count == 8)
    }

    @Test func eachLookSaysWhatItDraws() {
        #expect(!SidebarGroupBackgroundStyle.chip.indentsMembers && SidebarGroupBackgroundStyle.chip.drawsMembersMark)
        #expect(SidebarGroupBackgroundStyle.tree.indentsMembers && SidebarGroupBackgroundStyle.tree.leadsWithFolder)
        #expect(SidebarGroupBackgroundStyle.card.drawsCard && !SidebarGroupBackgroundStyle.card.indentsMembers)
        #expect(!SidebarGroupBackgroundStyle.folder.drawsMembersMark && !SidebarGroupBackgroundStyle.sections.drawsMembersMark)
        for style in [SidebarGroupBackgroundStyle.chip, .tree, .card, .folder] {
            #expect(!style.drawsBackground, "\(style) draws a header band")
            #expect(!style.drawsOnTabStrip, "\(style) is a sidebar look only")
        }
        for style in [SidebarGroupBackgroundStyle.auto, .glass, .solid, .sections] {
            #expect(style.drawsOnTabStrip, "\(style) lost its tab strip look")
        }
    }

    /// A tab strip has no rail, guide or card: its chips keep the automatic look under these three.
    @Test func theTabStripKeepsTheAutomaticLook() {
        for style in [SidebarGroupBackgroundStyle.chip, .tree, .card] {
            let chip = GroupChipGlass(glass: .vivid, background: style, palette: .glass)
            let auto = GroupChipGlass(glass: .vivid, background: .auto, palette: .glass)
            #expect(chip.drawsGlass == auto.drawsGlass, "\(style) changed the tab strip's chips")
        }
    }

    // MARK: chip

    /// The header is a slim chip hugging the name, not a full-width bar; its ink holds 4.5:1 on the chip and the chip
    /// stays visible against the sidebar, for every tint (no color too) in a dark, a light and a wallpaper room.
    @Test func aChipHugsTheNameAndKeepsItsContrast() throws {
        var failures: [String] = []
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            for tint in Self.tints {
                let label = "\(name) \(tint.wire)"
                let header = Self.header(.chip, tint, in: scope)
                if header.pill.frame.width >= header.bounds.width - 40 { failures.append("\(label): the chip \(header.pill.frame) spans the row") }
                if header.pill.frame.maxX < header.name.frame.maxX { failures.append("\(label): the chip ends before the name") }
                if header.pill.frame.minX > header.glyph.frame.minX && !header.glyph.isHidden { failures.append("\(label): the glyph starts left of the chip") }
                let fill = try GroupPaletteDefaultTests.rgb(header.pill.backgroundColor)
                let ink = try GroupPaletteDefaultTests.rgb(header.ink?.cgColor)
                if ink.contrast(with: fill) < 4.5 { failures.append("\(label): ink \(ink) on chip \(fill) is \(ink.contrast(with: fill)):1") }
                if fill.contrast(with: scope.tokens.sidebarBackground.withAlpha(1)) < GroupBackground.minimumVisibleContrast {
                    failures.append("\(label): the chip is invisible on the sidebar")
                }
                if !header.rim.isHidden { failures.append("\(label): a rim") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) chip headers off:\n" + failures.joined(separator: "\n")))
    }

    /// Chromium's model: no indent. The members keep the loose rows' x and each open group, colored or not, runs a
    /// rail beside them in its color; there is no block.
    @Test(arguments: [GroupTint.none, GroupTint.palette(.blue)])
    func chipMembersKeepTheLooseRowsXAndRunARail(tint: GroupTint) throws {
        let (sidebar, window) = Self.sidebar(.chip, tint: tint)
        defer { window.close() }
        let list = sidebar.list
        let loose = try #require(list.rowViews[.workspace(Self.looseID)])
        let member = try #require(list.rowViews[.workspace(Self.memberID)])
        #expect(member.frame.minX == loose.frame.minX, "a chip's member sits at \(member.frame.minX), loose rows at \(loose.frame.minX)")
        let line = try #require(list.groupLineViews.lines.first { $0.group == Self.group }, "an open chip group has no line")
        #expect(!line.isBlock, "a chip group drew a block")
        #expect(line.frame.maxX <= member.frame.minX, "the rail \(line.frame) runs under the members' fills")
        #expect(line.color == tint, "the rail is \(line.color), the group's color is \(tint)")
    }

    // MARK: tree

    /// The tree is the folder: glyph and indent, members' text on the name's column, plus one thin guide line
    /// centered under the glyph, between the header and the last member, left of the members' fills.
    @Test(arguments: [GroupTint.none, GroupTint.palette(.blue)])
    func treeGuideSitsUnderTheFolderGlyph(tint: GroupTint) throws {
        let (sidebar, window) = Self.sidebar(.tree, tint: tint)
        defer { window.close() }
        let list = sidebar.list
        let header = try #require(list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        let member = try #require(list.rowViews[.workspace(Self.memberID)])
        let last = try #require(list.rowViews[.workspace(Self.otherID)])
        #expect(!header.glyph.isHidden, "a tree header shows no folder glyph")
        #expect(member.frame.minX > header.frame.minX, "a tree's members are not indented")
        let line = try #require(list.groupLineViews.lines.first { $0.group == Self.group }, "an open tree group has no guide")
        let glyphMid = header.convert(header.glyph.frame, to: list).midX
        #expect(abs(line.frame.midX - glyphMid) < 1, "the guide is at \(line.frame.midX), the glyph's middle at \(glyphMid)")
        #expect(line.frame.width <= 1.5, "the guide is \(line.frame.width) pt wide")
        #expect(line.frame.maxX <= member.frame.minX, "the guide \(line.frame) runs under the members' fills")
        #expect(line.frame.minY >= header.frame.midY, "the guide starts above the folder glyph")
        #expect(line.frame.maxY <= last.frame.maxY && line.frame.maxY > member.frame.midY, "the guide ends at \(line.frame.maxY), outside the members")
    }

    /// The guide is a mark: 3:1 on the sidebar, a group with no color included.
    @Test func theGuideHoldsThreeToOneInEveryRoom() throws {
        var failures: [String] = []
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            for tint in Self.tints {
                let view = Self.lineView(.tree, tint, block: false, in: scope)
                let ink = try GroupPaletteDefaultTests.rgb(view.layer?.backgroundColor)
                let ratio = ink.contrast(with: scope.tokens.sidebarBackground.withAlpha(1))
                if ratio < 3 { failures.append("\(name) \(tint.wire): the guide is \(ratio):1") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    // MARK: card

    /// One block around every group, colored or not, header and members, its edge outset into the list's inset; a
    /// folded group is its header's block alone. The members keep the loose rows' x.
    @Test(arguments: [GroupTint.none, GroupTint.palette(.red)])
    func aCardWrapsTheWholeGroup(tint: GroupTint) throws {
        let (sidebar, window) = Self.sidebar(.card, tint: tint)
        defer { window.close() }
        let list = sidebar.list
        let loose = try #require(list.rowViews[.workspace(Self.looseID)])
        let header = try #require(list.rowViews[.group(Self.group)])
        let member = try #require(list.rowViews[.workspace(Self.memberID)])
        let last = try #require(list.rowViews[.workspace(Self.otherID)])
        #expect(member.frame.minX == loose.frame.minX && header.frame.minX == loose.frame.minX, "a card moved its rows")
        let line = try #require(list.groupLineViews.lines.first { $0.group == Self.group }, "an open card group has no card")
        #expect(line.isBlock && line.color == tint, "the card is not a block in the group's color")
        #expect(line.frame.minY <= header.frame.minY && line.frame.maxY >= last.frame.maxY, "the card \(line.frame) does not wrap its rows")
        #expect(line.frame.minX < header.frame.minX && line.frame.maxX > header.frame.maxX - 0.5, "the card does not reach past its rows")
        #expect(line.rail == nil, "a card draws a rail inside")
        sidebar.model.setGroupCollapsed(Self.group, true)
        list.reload(animated: false)
        let folded = try #require(list.groupLineViews.lines.first { $0.group == Self.group }, "a folded card group has no card")
        #expect(folded.isBlock && abs(folded.frame.height - header.frame.height) < 0.5, "a folded card is \(folded.frame.height) pt, its header \(header.frame.height)")
    }

    /// The card's wash shows against the sidebar, its edge is a 3:1 mark, and the header's primary ink holds 4.5:1 on it.
    @Test func theCardHoldsItsContrastInEveryRoom() throws {
        var failures: [String] = []
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let ground = scope.tokens.sidebarBackground.withAlpha(1)
            for tint in Self.tints {
                let view = Self.lineView(.card, tint, block: true, in: scope)
                let fill = try GroupPaletteDefaultTests.rgb(view.layer?.backgroundColor)
                let edge = try GroupPaletteDefaultTests.rgb(view.layer?.borderColor)
                if fill.contrast(with: ground) < 1.02 { failures.append("\(name) \(tint.wire): the card is invisible (\(fill.contrast(with: ground)):1)") }
                if scope.tokens.textPrimary.withAlpha(1).contrast(with: fill) < 4.5 { failures.append("\(name) \(tint.wire): the primary ink is under 4.5:1 on the card") }
                if edge.contrast(with: ground) < 3 { failures.append("\(name) \(tint.wire): the card's edge is \(edge.contrast(with: ground)):1") }
                let header = Self.header(.card, tint, in: scope)
                let ink = try GroupPaletteDefaultTests.rgb(header.ink?.cgColor)
                if !GroupPaletteDefaultTests.same(ink, scope.tokens.textPrimary) { failures.append("\(name) \(tint.wire): the name is not in the primary ink") }
                if !header.pill.isHidden, GroupHeaderAlwaysVisibleTests.rgba(header.pill.backgroundColor).alpha > 0.001 { failures.append("\(name) \(tint.wire): the header paints its own band") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// Hover and a drop still give the header its row fills in each look.
    @Test(arguments: [SidebarGroupBackgroundStyle.chip, .tree, .card])
    func hoverAndDropStillShow(style: SidebarGroupBackgroundStyle) throws {
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let header = Self.header(style, .palette(.blue), in: scope)
            header.isHovered = true
            header.updateLayer()
            #expect(header.debugFill, "\(name) \(style): no fill under the pointer")
            header.isHovered = false
            header.isDropTarget = true
            header.updateLayer()
            #expect(header.debugFill, "\(name) \(style): no fill under a drop")
        }
    }

    // MARK: strings

    /// The three choices carry a title in every language the catalog has.
    @Test func theChoicesAreLocalizedEverywhere() throws {
        // The table is one file per key (Localizable.xcstrings.d/<key>.xcstrings, scripts/cmux-next/string_catalogs.py).
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextSettings/Localizable.xcstrings.d")
        var strings: [String: [String: Any]] = [:]
        for name in ["Folder", "Chip", "Tree", "Card"] {
            let url = directory.appendingPathComponent("settings.choice.groupBackground\(name).xcstrings")
            let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            for (key, entry) in try #require(catalog["strings"] as? [String: [String: Any]]) { strings[key] = entry }
        }
        let folder = try #require((strings["settings.choice.groupBackgroundFolder"]?["localizations"] as? [String: Any])?.keys)
        for key in ["Chip", "Tree", "Card"] {
            let locales = try #require((strings["settings.choice.groupBackground\(key)"]?["localizations"] as? [String: Any])?.keys, "\(key) has no strings")
            #expect(Set(locales) == Set(folder) && locales.count == 21, "\(key) is in \(locales.count) languages, Folders in \(folder.count)")
        }
    }
}
