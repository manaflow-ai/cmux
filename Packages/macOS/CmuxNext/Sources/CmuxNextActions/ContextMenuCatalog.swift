/// One entry of a declared context menu.
public enum ContextMenuEntry: Sendable, Hashable {
    case action(ActionID)
    case separator
    /// A submenu titled by an action's title (without its ellipsis).
    case submenu(ActionID, [ContextMenuEntry])
    /// A submenu titled by an action, one item per value of its first
    /// enumeration argument (Set Room Theme > Nord, Vesper, ...). Hovering
    /// an item previews it (`ActionRegistry.choicePreview`).
    case choices(ActionID)
}

/// Right-click menus generated from the actions' placements
/// (`ActionDescriptor.surfacePlan.contextMenus`). No menu is a hand list:
/// an action appears in a menu exactly when it declares a placement there,
/// so a menu cannot drift from the catalog. The registry renders the
/// entries (`ActionRegistry.makeContextMenu`) with titles, shortcuts and
/// enabled state.
public struct ContextMenuCatalog: Sendable {
    public static let shared = Self(descriptors: ActionCatalog.all)

    private let menus: [ActionMenuContext: [ContextMenuEntry]]

    public init(descriptors: [ActionDescriptor]) {
        var rows: [ActionMenuContext: [Row]] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            for placement in descriptor.surfacePlan.contextMenus {
                rows[placement.context, default: []].append(Row(id: descriptor.id, placement: placement, index: index))
            }
        }
        menus = rows.mapValues { Self.entries($0.filter { $0.placement.parent == nil }, all: $0) }
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
            }
        }
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
