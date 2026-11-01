import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/25653: a workspace's color showed only as a small
/// dot, and classic's `workspaceColors.indicatorStyle` did nothing in NEXT. The setting now picks a
/// dot (the default), a leading rail or a full-row fill, for loose rows and group members alike,
/// and a color set on a grouped workspace shows at once.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WorkspaceColorFillTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private static func preferences(_ style: String?) -> SidebarSectionsPreferences {
        let root: CmuxNextSettings.JSONValue = style.map { .object(["workspaceColors": .object(["indicatorStyle": .string($0)])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).sidebarSections
    }

    /// A loose red workspace, and a group holding a green one and an uncolored one.
    private static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("loose"), title: "loose", icon: .swatch(.red), color: .red)),
            .group(CmuxNextSidebar.SidebarGroup(id: GroupID("g"), name: "Ready for review", color: .blue, workspaces: [
                SidebarWorkspace(id: WorkspaceID("member"), title: "member", icon: .symbol("star", tint: .green), color: .green),
                SidebarWorkspace(id: WorkspaceID("plain"), title: "plain"),
            ])),
        ])]
    }

    private static func contents(_ model: SidebarModel) -> [String: WorkspaceRowContent] {
        let layout = SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
        var result: [String: WorkspaceRowContent] = [:]
        for row in layout.rows {
            if case let .workspace(id) = row.key, let content = row.content { result[id.rawValue] = content }
        }
        return result
    }

    @Test func theSettingIsListedAndDefaultsToTheDot() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["workspaceColors", "indicatorStyle"]))
        #expect(row.defaultValue == .string("dot"))
        #expect(Self.preferences(nil).workspaceColorIndicator == .dot)
    }

    @Test func eachStyleParsesAndClassicsSolidFillReadsAsFill() {
        #expect(Self.preferences("fill").workspaceColorIndicator == .fill)
        #expect(Self.preferences("leftRail").workspaceColorIndicator == .leftRail)
        #expect(Self.preferences("solidFill").workspaceColorIndicator == .fill)
        for legacy in ["rail", "border", "wash", "lift", "typography", "washRail", "blueWashColorRail"] {
            let snapshot = CmuxConfigSnapshot.parse(.object(["workspaceColors": .object(["indicatorStyle": .string(legacy)])]),
                                                    validDensities: [], validMetrics: [])
            #expect(snapshot.sidebarSections.workspaceColorIndicator == .leftRail, "classic's \(legacy) reads as the rail")
            #expect(!snapshot.diagnostics.contains { $0.path == "workspaceColors.indicatorStyle" })
        }
        let root: CmuxNextSettings.JSONValue = .object(["workspaceColors": .object(["indicatorStyle": .string("glow")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.sidebarSections.workspaceColorIndicator == .dot, "a bad value keeps the default")
        #expect(snapshot.diagnostics.contains { $0.path == "workspaceColors.indicatorStyle" })
    }

    @Test func theFillStyleColorsLooseAndGroupedRows() {
        let model = SidebarModel(sections: Self.sections())
        model.applyListPreferences(Self.preferences("fill"))
        let rows = Self.contents(model)
        #expect(rows["loose"]?.rowColor == .red && rows["loose"]?.colorStyle == .fill)
        #expect(rows["loose"]?.icon == nil, "the fill says the color; no dot repeats it")
        #expect(rows["member"]?.rowColor == .green, "a group member fills with its own color, not the group's")
        #expect(rows["member"]?.icon == .symbol("star", tint: .green), "a chosen symbol keeps its tint")
        #expect(rows["plain"]?.rowColor == nil, "an uncolored member takes neither its group's color nor a fill")
    }

    @Test func theDotStyleAndColorsOffDrawNoFill() {
        let model = SidebarModel(sections: Self.sections())
        model.applyListPreferences(Self.preferences(nil))
        #expect(Self.contents(model)["loose"]?.rowColor == nil)
        #expect(Self.contents(model)["loose"]?.icon == .swatch(.red))
        var hidden = Self.preferences("fill")
        hidden.showColors = false
        model.applyListPreferences(hidden)
        #expect(Self.contents(model)["loose"]?.rowColor == nil)
    }

    /// The row menu, the palette and `cmux workspace set-color --target` all end in `.setColor`: a
    /// workspace inside a group, and one with no icon of its own, fill with the new color at once.
    @Test func coloringAGroupedWorkspaceFillsItsRowAtOnce() {
        let model = SidebarModel(sections: Self.sections())
        model.applyListPreferences(Self.preferences("fill"))
        model.send(.setColor([WorkspaceID("plain")], .orange))
        #expect(Self.contents(model)["plain"]?.rowColor == .orange)
        model.send(.setColor([WorkspaceID("member")], nil))
        #expect(Self.contents(model)["member"]?.rowColor == nil, "Reset Workspace Color takes the fill away")
    }

    /// Switching the style in Settings redraws the rows already on screen: `changesList` gated the
    /// list's redraw, and without the style in it a shown row kept its dot until something else
    /// reconfigured it (a status tick), so the sidebar showed dots and fills mixed.
    @Test func changingTheStyleRedrawsShownRows() throws {
        let design = DesignSettings()
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections()), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false) // realize the rows (DensitySidebarOverflowTests); not after the change below
        let before = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("member"))] as? WorkspaceRowView)
        #expect(before.rowColor == nil, "the dot style draws no fill")
        design.sidebarSections = Self.preferences("fill")
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        let after = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("member"))] as? WorkspaceRowView)
        #expect(after.rowColor?.color == .green && after.rowColor?.style == .fill, "the grouped row fills without another change")
    }

    private static func rowView(_ ws: SidebarWorkspace, style: String, selected: Bool = false) -> (WorkspaceRowView, NSWindow) {
        var options = SidebarLayoutOptions()
        options.colorIndicator = Self.preferences(style).workspaceColorIndicator
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: options.rowContent(ws, machine: nil))
        let view = WorkspaceRowView(key: row.key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row)
        view.isSelected = selected
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        return (view, window)
    }

    @Test func aFillRowPaintsItsColorAtRestAndStillReadsAsSelected() throws {
        let colored = SidebarWorkspace(id: WorkspaceID("ws"), title: "PR ready", icon: .swatch(.green), color: .green)
        let (rest, restWindow) = Self.rowView(colored, style: "fill")
        #expect(rest.debugFill, "an idle, unselected colored row is filled")
        let (plain, plainWindow) = Self.rowView(SidebarWorkspace(id: WorkspaceID("p"), title: "plain"), style: "fill")
        #expect(!plain.debugFill, "an uncolored row keeps the plain sidebar")
        let (selected, selectedWindow) = Self.rowView(colored, style: "fill", selected: true)
        let restAlpha = try #require(rest.layer?.backgroundColor?.alpha)
        let selectedAlpha = try #require(selected.layer?.backgroundColor?.alpha)
        #expect(selectedAlpha > restAlpha, "selection steps the fill up")
        for view in [rest, selected] {
            let fill = try #require(view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
            let swatch = try #require(GroupColor.green.swatch.usingColorSpace(.sRGB))
            #expect(abs(fill.redComponent - swatch.redComponent) < 0.01 && abs(fill.greenComponent - swatch.greenComponent) < 0.01
                && abs(fill.blueComponent - swatch.blueComponent) < 0.01, "the fill is the workspace's color, not the gray selection")
        }
        [restWindow, plainWindow, selectedWindow].forEach { $0.closeAfterTest() }
    }

    @Test func aLeftRailRowDrawsABarDownItsEdge() {
        let (view, window) = Self.rowView(SidebarWorkspace(id: WorkspaceID("ws"), title: "PR ready", icon: .swatch(.blue), color: .blue), style: "leftRail")
        #expect(!view.colorRail.isHidden && view.colorRail.superview === view)
        #expect(view.colorRail.frame.width == WorkspaceRowView.colorRailWidth && view.colorRail.frame.height > 0)
        #expect(!view.debugFill, "the rail style leaves the row unfilled")
        window.closeAfterTest()
    }

    /// Visual review of https://github.com/manaflow-ai/cmux/pull/25705: the rail ended a point or two before the
    /// title's first letter. A rail row's title sits where the dot style puts it, past the dot's slot.
    @Test func aLeftRailRowsTitleStaysWhereTheDotStylePutsIt() {
        let ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "PR ready", icon: .swatch(.green), color: .green)
        let (dot, dotWindow) = Self.rowView(ws, style: "dot")
        let (rail, railWindow) = Self.rowView(ws, style: "leftRail")
        #expect(rail.title.frame.minX == dot.title.frame.minX)
        #expect(rail.title.frame.minX - rail.colorRail.frame.maxX >= Metrics.space3, "clear of the rail")
        [dotWindow, railWindow].forEach { $0.closeAfterTest() }
    }

    @Test func aStartedWorkspacesRailMovesInWithItsContent() {
        let ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "child", color: .blue)
        let (top, topWindow) = Self.rowView(ws, style: "leftRail")
        let (nested, nestedWindow) = Self.rowView(ws, style: "leftRail")
        nested.treeDepth = 1
        nested.needsLayout = true
        nested.layoutSubtreeIfNeeded()
        #expect(nested.colorRail.frame.minX == top.colorRail.frame.minX + SidebarStyle.treeIndent)
        [topWindow, nestedWindow].forEach { $0.closeAfterTest() }
    }

    @Test func aSavedSidebarKeepsEachWorkspacesColor() throws {
        let saved = SidebarSnapshot(sections: Self.sections(), profiles: [], activeProfileID: nil)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(saved))
        let rows = decoded.sidebarSections.flatMap(\.nodes).flatMap { node -> [SidebarWorkspace] in
            switch node {
            case let .workspace(ws): [ws]
            case let .group(group): group.workspaces
            default: []
            }
        }
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.id.rawValue, $0.color) }) == ["loose": .red, "member": .green, "plain": nil])
    }
}
