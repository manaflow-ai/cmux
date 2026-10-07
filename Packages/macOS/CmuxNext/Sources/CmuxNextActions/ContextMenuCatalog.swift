/// One entry of a declared context menu.
public nonisolated enum ContextMenuEntry: Sendable, Hashable {
    case action(ActionID)
    case separator
    /// A submenu titled by an action's title (without its ellipsis).
    case submenu(ActionID, [ContextMenuEntry])
    /// A submenu titled by an action, one item per value of its first
    /// enumeration argument (Set Room Theme > Nord, Vesper, ...). Hovering
    /// an item previews it (`ActionRegistry.choicePreview`).
    case choices(ActionID)
    /// A titled submenu of less used rows ("Move ▸").
    case folder(MenuFolder, [ContextMenuEntry])
}

/// Right-click menus generated from the actions' placements
/// (`ActionDescriptor.surfacePlan.contextMenus`). No menu is a hand list:
/// an action appears in a menu exactly when it declares a placement there,
/// so a menu cannot drift from the catalog. The registry renders the
/// entries (`ActionRegistry.makeContextMenu`) with titles, shortcuts and
/// enabled state.
public nonisolated struct ContextMenuCatalog: Sendable {
    public static let shared = Self(descriptors: ActionCatalog.all)

    private let menus: [ActionMenuContext: [ContextMenuEntry]]

    public init(descriptors: [ActionDescriptor]) {
        var rows: [ActionMenuContext: [Row]] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            for placement in descriptor.surfacePlan.contextMenus {
                rows[placement.context, default: []].append(Row(id: descriptor.id, placement: placement, index: index))
            }
        }
        menus = rows.mapValues { Self.topLevel($0) }
    }

    public func entries(for context: ActionMenuContext) -> [ContextMenuEntry] {
        menus[context] ?? []
    }

    /// Every action ID an entry list references, submenus included.
    public func referencedIDs(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id): [id]
            case .separator: []
            case .submenu(let id, let children): [id] + referencedIDs(children)
            case .choices(let id): [id]
            case .folder(_, let children): referencedIDs(children)
            }
        }
    }

    /// The menu for `context` without `hidden` rows, inside folders too
    /// (call-site filters: a page tab hides terminal themes). A folder left
    /// empty disappears; the registry collapses separator runs.
    public func entries(for context: ActionMenuContext, removing hidden: Set<ActionID>) -> [ContextMenuEntry] {
        Self.removing(hidden, from: entries(for: context))
    }

    static func removing(_ hidden: Set<ActionID>, from entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        var result: [ContextMenuEntry] = []
        for entry in entries {
            switch entry {
            case .action(let id), .choices(let id):
                if !hidden.contains(id) { result.append(entry) }
            case .separator:
                result.append(entry)
            case .submenu(let id, let children):
                if !hidden.contains(id) { result.append(.submenu(id, removing(hidden, from: children))) }
            case .folder(let folder, let children):
                let kept = removing(hidden, from: children)
                if kept.contains(where: { if case .separator = $0 { false } else { true } }) { result.append(.folder(folder, kept)) }
            }
        }
        return result
    }

    /// The cmux items after an engine's own page menu (Chromium lists Back,
    /// Forward and Reload itself): the page menu without that group.
    public var browserPageAfterEngineMenu: [ContextMenuEntry] {
        let navigation: Set<ActionID> = ["browserBack", "browserForward", "browserReload"]
        var entries = entries(for: .browserPage).filter { if case .action(let id) = $0 { !navigation.contains(id) } else { true } }
        while case .separator? = entries.first { entries.removeFirst() }
        return entries
    }

    private struct Row {
        let id: ActionID
        let placement: ContextMenuPlacement
        let index: Int
    }

    /// A top-level menu: unfoldered rows plus one row per folder at the
    /// folder's position. A folder with one row shows it inline.
    private static func topLevel(_ rows: [Row]) -> [ContextMenuEntry] {
        let roots = rows.filter { $0.placement.parent == nil }
        // Folders follow their group's rows, in the group's last section.
        var items: [(group: MenuGroup, folder: Int, rank: Int, index: Int, band: Int, entries: [ContextMenuEntry])] = []
        var lastBand: [MenuGroup: Int] = [:]
        func addRow(_ row: Row) {
            let band = row.placement.rank / 100
            lastBand[row.placement.group] = max(lastBand[row.placement.group] ?? band, band)
            items.append((row.placement.group, 0, row.placement.rank, row.index, band, entries([row], all: rows)))
        }
        for row in roots where row.placement.folder == nil { addRow(row) }
        var folders: [(MenuFolder, [Row])] = []
        for folder in MenuFolder.allCases {
            let members = roots.filter { $0.placement.folder == folder }
            if members.count == 1, let only = members.first { addRow(only) } else if !members.isEmpty { folders.append((folder, members)) }
        }
        for (folder, members) in folders {
            let index = MenuFolder.allCases.firstIndex(of: folder) ?? 0
            items.append((folder.group, 1, index, index, lastBand[folder.group] ?? 0, [.folder(folder, entries(members, all: rows))]))
        }
        items.sort { ($0.group, $0.folder, $0.rank, $0.index) < ($1.group, $1.folder, $1.rank, $1.index) }
        var result: [ContextMenuEntry] = []
        var lastSection: (MenuGroup, Int)?
        for item in items {
            let section = (item.group, item.band)
            if let lastSection, lastSection != section { result.append(.separator) }
            lastSection = section
            result += item.entries
        }
        return result
    }

    /// Orders `rows` by group, rank and catalog order, with a separator
    /// between groups and between rank hundreds inside a group.
    private static func entries(_ rows: [Row], all: [Row]) -> [ContextMenuEntry] {
        let sorted = rows.sorted {
            ($0.placement.group, $0.placement.rank, $0.index) < ($1.placement.group, $1.placement.rank, $1.index)
        }
        var result: [ContextMenuEntry] = []
        var lastSection: (MenuGroup, Int)?
        for row in sorted {
            let section = (row.placement.group, row.placement.rank / 100)
            if let lastSection, lastSection != section { result.append(.separator) }
            lastSection = section
            switch row.placement.style {
            case .item: result.append(.action(row.id))
            case .choices: result.append(.choices(row.id))
            case .submenu:
                let children = all.filter { $0.placement.parent == row.id }
                result.append(.submenu(row.id, entries(children, all: all)))
            }
        }
        return result
    }
}
