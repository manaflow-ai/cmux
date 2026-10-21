import AppKit
@testable import CmuxNextActions
import Testing

/// The shape of every right-click menu as people see it, and as the export hands it to other
/// clients (cmuxterm-hq#2015, the menu audit's safe set): no empty sections, no one-row or
/// untitled submenus, one toggle style, no palette prefixes, global sidebar settings on the
/// sidebar only, and the group menus in the group editor's words.
@MainActor
struct ContextMenuShapeTests {
    private let menus = ContextMenuCatalog.shared
    private let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// One row of a menu as it reads: its title and, for a submenu or folder, its rows.
    private struct Row {
        var id: ActionID?
        var title: String
        var children: [Row]?
        var isSeparator = false
    }

    /// The rows of `context`, titled like `ActionRegistry.makeContextMenu` titles them
    /// (a menu label, else the action's title; a submenu without its ellipsis).
    private func rows(_ context: ActionMenuContext) -> [Row] {
        rows(menus.entries(for: context), labels: menus.labels(for: context))
    }

    private func rows(_ entries: [ContextMenuEntry], labels: [ActionID: String]) -> [Row] {
        entries.map { entry in
            switch entry {
            case .separator: Row(id: nil, title: "—", children: nil, isSeparator: true)
            case .action(let id): Row(id: id, title: labels[id] ?? byID[id]?.title ?? id.rawValue, children: nil)
            case .choices(let id): Row(id: id, title: dropEllipsis(labels[id] ?? byID[id]?.title ?? id.rawValue), children: nil)
            case .submenu(let id, let children):
                Row(id: id, title: dropEllipsis(labels[id] ?? byID[id]?.title ?? id.rawValue), children: rows(children, labels: labels))
            case .folder(let folder, let children): Row(id: nil, title: folder.title, children: rows(children, labels: labels))
            }
        }
    }

    private func dropEllipsis(_ title: String) -> String { title.hasSuffix("…") ? String(title.dropLast()) : title }

    /// Every row at any depth, with the submenu titles that lead to it.
    private func flatten(_ rows: [Row], path: [String] = []) -> [(path: [String], row: Row)] {
        rows.flatMap { row -> [(path: [String], row: Row)] in
            [(path, row)] + (row.children.map { flatten($0, path: path + [row.title]) } ?? [])
        }
    }

    private func ids(_ rows: [Row]) -> [ActionID] { flatten(rows).compactMap { $0.row.children == nil ? $0.row.id : nil } }

    private func submenu(_ title: String, in rows: [Row]) -> [Row]? { rows.first { $0.title == title }?.children }

    @Test func noMenuHasAnEmptySection() {
        func check(_ list: [Row], _ place: String) {
            #expect(list.first?.isSeparator != true, "\(place) starts with a separator")
            #expect(list.last?.isSeparator != true, "\(place) ends with a separator")
            for (a, b) in zip(list, list.dropFirst()) {
                #expect(!(a.isSeparator && b.isSeparator), "\(place): two separators in a row after \(a.title)")
            }
            for row in list { if let children = row.children { check(children, "\(place) › \(row.title)") } }
        }
        for context in ActionMenuContext.allCases { check(rows(context), "\(context)") }
    }

    @Test func noSubmenuHoldsASingleRow() {
        for context in ActionMenuContext.allCases {
            for (path, row) in flatten(rows(context)) {
                guard let children = row.children else { continue }
                let count = children.filter { !$0.isSeparator }.count
                #expect(count >= 2, "\(context) \((path + [row.title]).joined(separator: " › ")) holds \(count) row")
            }
        }
    }

    /// Toggles read "Pin/Unpin", never "Pin or Unpin" or "Toggle Group Collapse"; menus drop the
    /// palette's prefixes ("Agent Chat: Zoom In", "Column Width: Half", "Tab Group Color: Grey").
    @Test func menuTitlesUseOneToggleStyleAndNoPalettePrefixes() {
        for context in ActionMenuContext.allCases {
            for (path, row) in flatten(rows(context)) where !row.isSeparator {
                let place = "\(context) \((path + [row.title]).joined(separator: " › "))"
                #expect(!row.title.contains(" or "), "\(place): a toggle reads X/Y")
                #expect(!row.title.hasPrefix("Toggle Group"), "\(place): a toggle reads X/Y")
                #expect(!row.title.contains(": "), "\(place): a palette prefix")
            }
        }
    }

    /// Each group's and screen's color list is a submenu titled Color, of color names: in
    /// Appearance ▸, or at the top level of a workspace group's flat menu (Lawrence 2026-10-20).
    @Test func colorSubmenusAreTitledColor() throws {
        for (context, prefix) in [(ActionMenuContext.tabGroup, "tabGroup"), (.workspaceGroup, "workspaceGroup"),
                                  (.screen, "screen"), (.screenGroup, "screenGroup")] {
            let appearance = try #require(context == .workspaceGroup ? rows(context) : submenu("Appearance", in: rows(context)),
                                          "\(context) has Appearance")
            let color = try #require(appearance.first { $0.id == ActionID(rawValue: "\(prefix).setColor") }, "\(context) has a color submenu")
            #expect(color.title == "Color", "\(context): the color submenu reads \(color.title)")
            #expect(color.children?.contains { $0.title == "Blue" } == true, "\(context): Color › Blue")
        }
    }

    /// The pane menu keeps Split Right and Split Down on top and puts the other splits beside
    /// them in Split, not in More › New.
    @Test func thePaneMenuKeepsItsSplitsTogether() throws {
        let pane = rows(.pane)
        #expect(Array(pane.prefix(3).map(\.title)) == ["Split Right", "Split Down", "Split"])
        let split = try #require(submenu("Split", in: pane))
        #expect(ids(split).contains("splitLeft") && ids(split).contains("splitUp"))
        let new = submenu("New", in: submenu("More", in: pane) ?? []) ?? []
        #expect(!ids(new).contains("splitLeft") && !ids(new).contains("splitUp"))
    }

    /// Save Layout as Template moves next to New Workspace from Template, so the row's More
    /// has no one-row Group submenu.
    @Test func theWorkspaceRowHasNoOneRowGroupSubmenu() throws {
        let row = rows(.workspaceRow)
        let more = try #require(submenu("More", in: row))
        #expect(submenu("Group", in: more) == nil)
        #expect(ids(submenu("New", in: more) ?? []).contains("saveLayoutTemplate"))
    }

    /// The sidebar's Sort submenu is called Sort; a section's menu names what each Hide hides.
    @Test func theSidebarMenusNameWhatTheyDo() throws {
        let background = rows(.sidebarBackground)
        let sort = try #require(submenu("Sort", in: background))
        #expect(ids(sort) == ["workspace.sortByName", "workspace.sortByLastUsed", "workspace.sortByDirectory"])
        #expect(submenu("Move", in: background) == nil)
        let titles = flatten(rows(.sidebarSection)).map(\.row.title)
        #expect(!titles.contains("Hide"))
        #expect(titles.contains("Hide App"))
    }

    /// A group's own menu drops the group's noun and uses the group editor's words for the
    /// rows the editor shows (SidebarGroupEditorControls: Close Group, Ungroup, Move to New Window).
    @Test func groupMenusUseTheGroupEditorsWords() {
        func title(_ id: ActionID, in context: ActionMenuContext) -> String? {
            flatten(rows(context)).first { $0.row.id == id }?.row.title
        }
        #expect(title("workspaceGroup.closeWorkspaces", in: .workspaceGroup) == "Close Group")
        #expect(title("workspaceGroup.ungroup", in: .workspaceGroup) == "Ungroup")
        #expect(title("workspaceGroup.moveToNewWindow", in: .workspaceGroup) == "Move to New Window")
        #expect(title("tabGroup.close", in: .tabGroup) == "Close Group")
        #expect(title("tabGroup.ungroup", in: .tabGroup) == "Ungroup")
        #expect(title("tabGroup.moveLeft", in: .tabGroup) == "Move Left")
        #expect(title("screenGroup.moveToNewWindow", in: .screenGroup) == "Move to New Window")
        #expect(title("screen.moveRight", in: .screen) == "Move Right")
        // The palette keeps the noun.
        #expect(byID["tabGroup.moveLeft"]?.title == "Move Tab Group Left")
    }

    /// A row's live title for its target ("Expand Section") still wins over its menu label.
    @Test func aTargetTitleWinsOverTheMenuLabel() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("sidebar.section.toggleCollapsed", invoke: { _ in })
        ActionTargetTitles.set("sidebar.section.toggleCollapsed", in: registry) { _ in "Expand Section" }
        let menu = registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: "s"))
        let item = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "sidebar.section.toggleCollapsed" })
        #expect(item.title == "Expand Section")
    }
}
