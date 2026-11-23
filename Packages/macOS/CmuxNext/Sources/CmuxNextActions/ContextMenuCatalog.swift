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
    /// A submenu the person made in Settings > Menus (``ContextMenuLayout``), with its title.
    case group(ContextMenuGroup, [ContextMenuEntry])
}

/// Right-click menus generated from the actions' placements
/// (`ActionDescriptor.surfacePlan.contextMenus`). No menu is a hand list:
/// an action appears in a menu exactly when it declares a placement there,
/// so a menu cannot drift from the catalog. Rust builds the trees
/// (cmux-action-catalog `context_menus`, `RustActionCatalog.contextMenus`);
/// the registry renders the entries (`ActionRegistry.makeContextMenu`) with
/// titles, shortcuts and enabled state.
public nonisolated struct ContextMenuCatalog: Sendable {
    public static let shared = Self(descriptors: ActionCatalog.all)

    private let menus: [ActionMenuContext: [ContextMenuEntry]]
    private let selectionMenus: [ActionMenuContext: [ContextMenuEntry]]
    private let labels: [ActionMenuContext: [ActionID: String]]

    public init(descriptors: [ActionDescriptor]) {
        var labels: [ActionMenuContext: [ActionID: String]] = [:]
        for descriptor in descriptors {
            for placement in descriptor.surfacePlan.contextMenus {
                if let label = placement.label { labels[placement.context, default: [:]][descriptor.id] = label }
            }
        }
        let trees = RustActionCatalog.shared.contextMenus
        menus = trees.filter { !$0.value.entries.isEmpty }.mapValues { $0.entries }
        selectionMenus = trees.compactMapValues { $0.selection }
        self.labels = labels
    }

    public func entries(for context: ActionMenuContext) -> [ContextMenuEntry] {
        menus[context] ?? []
    }

    /// The menu for `context` opened on one of several selected rows
    /// (``ContextMenuEssentials/selectionMenus``); the one-row menu where it has none.
    public func selectionEntries(for context: ActionMenuContext) -> [ContextMenuEntry] {
        selectionMenus[context] ?? entries(for: context)
    }

    /// The menu-only row titles of `context` (``ContextMenuPlacement/label``).
    public func labels(for context: ActionMenuContext) -> [ActionID: String] {
        labels[context] ?? [:]
    }

    /// Every action ID an entry list references, submenus included.
    public func referencedIDs(_ entries: [ContextMenuEntry]) -> [ActionID] {
        Self.referencedIDs(entries)
    }

    static func referencedIDs(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id): [id]
            case .separator: []
            case .submenu(let id, let children): [id] + referencedIDs(children)
            // A choices row's trailer is in its submenu (Move to Group > New Group).
            case .choices(let id): [id] + (ContextMenuEssentials.choiceTrailers[id].map { [$0] } ?? [])
            case .folder(_, let children), .group(_, let children): referencedIDs(children)
            }
        }
    }

    /// The menu for `context` without `hidden` rows, inside folders too
    /// (call-site filters: a page tab hides terminal themes). A folder left
    /// empty disappears; the registry collapses separator runs.
    public func entries(for context: ActionMenuContext, removing hidden: Set<ActionID>) -> [ContextMenuEntry] {
        Self.removing(hidden, from: entries(for: context))
    }

    public static func removing(_ hidden: Set<ActionID>, from entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
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
            case .group(let group, let children):
                let kept = removing(hidden, from: children)
                if kept.contains(where: { if case .separator = $0 { false } else { true } }) { result.append(.group(group, kept)) }
            }
        }
        return result
    }

    /// The cmux items after an engine's own page menu (Chromium lists Back,
    /// Forward and Reload itself): the page menu without that group.
    public var browserPageAfterEngineMenu: [ContextMenuEntry] {
        Self.afterEngineMenu(entries(for: .browserPage))
    }

    /// A page menu (`entries`) without the navigation rows an engine's own menu lists, wherever the
    /// person put them (Settings > Menus can move them into a submenu).
    static func afterEngineMenu(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        var entries = removing(["browserBack", "browserForward", "browserReload"], from: entries)
        while case .separator? = entries.first { entries.removeFirst() }
        return entries
    }
}
