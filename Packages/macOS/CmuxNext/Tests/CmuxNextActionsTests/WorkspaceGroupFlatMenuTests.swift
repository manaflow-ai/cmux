@testable import CmuxNextActions
import Testing

/// A group header's right-click menu is one flat menu (Lawrence 2026-10-20: "right now I need to
/// right-click and then go do more group actions … bring them into this normal UI";
/// plans/cmux-next/sidebar-ordering-DESIGN.md). The rows people use most sit at the top level,
/// like Finder's and Safari's tab group menus, and every row of the menu is also a palette command.
@MainActor @Suite struct WorkspaceGroupFlatMenuTests {
    /// The rows that must be one click away from a right-click on the header.
    nonisolated static let topLevel: [ActionID] = [
        "workspaceGroup.newWorkspace", "workspaceGroup.rename", "workspaceGroup.setColor", "workspaceGroup.togglePin",
        "toggleFocusedWorkspaceGroupCollapsed", "workspaceGroup.moveToTop", "workspaceGroup.ungroup",
        "workspaceGroup.closeWorkspaces",
    ]

    static func entries() -> [ContextMenuEntry] { ContextMenuCatalog.shared.entries(for: .workspaceGroup) }

    @Test(arguments: topLevel)
    func commonRowIsAtTheTopLevel(_ id: ActionID) {
        let top = Self.entries().compactMap { entry -> ActionID? in
            switch entry {
            case let .action(id), let .choices(id), let .submenu(id, _): id
            case .separator, .folder, .group: nil
            }
        }
        #expect(top.contains(id), "\(id) is not a top-level row of the group menu (inside a folder, or gone)")
    }

    /// No More ▸, Close ▸, Appearance ▸ or Group ▸ folder: a group's menu keeps only the folders
    /// that hold a list of like rows (Move ▸, Sort ▸, Options ▸).
    @Test func theGroupMenuHasNoCatchAllFolder() {
        let folders = Self.entries().compactMap { entry -> MenuFolder? in
            if case let .folder(folder, _) = entry { folder } else { nil }
        }
        for folder in [MenuFolder.more, .close, .appearance, .group] {
            #expect(!folders.contains(folder), "the group menu still folds rows into \(folder.title) ▸")
        }
    }

    /// Every action the group menu runs is also a Cmd-Shift-P command, so nothing is reachable only
    /// by a right-click. A color choice inside Color ▸ counts through its parent (Set Group Color).
    @Test func everyGroupMenuActionIsInThePalette() {
        func ids(_ entries: [ContextMenuEntry]) -> [ActionID] {
            entries.flatMap { entry -> [ActionID] in
                switch entry {
                case let .action(id), let .choices(id): [id]
                case let .submenu(id, _): [id]
                case let .folder(_, children), let .group(_, children): ids(children)
                case .separator: []
                }
            }
        }
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids(Self.entries()) {
            #expect(byID[id]?.surfacePlan.palette.isOffered == true, "\(id) is in the group menu but not in the palette")
        }
    }
}
