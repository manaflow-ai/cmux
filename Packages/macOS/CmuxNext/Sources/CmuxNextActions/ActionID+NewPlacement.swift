/// New ▸ {Terminal, Browser, Agent Chat, New Tab Page} ▸ the ten places Fork To forks to. The rows
/// are the Rust catalog's `NewPlacementActionCatalog` group (cmux-action-catalog,
/// `catalog/new_placement.rs`): a submenu per kind (`new.<kind>`), then its row per place
/// (`new.<kind>.<place>`). The app opens kind K at place P through one function
/// (`NewAtPlacement`), whose plan is the layout reducer's `new_placement`.
extension ActionID {
    /// The group's IDs in catalog order: each kind's submenu, then its places in Fork To's order.
    private static var newPlacementGroup: [ActionID] {
        ActionCatalog.descriptors(inGroup: "NewPlacementActionCatalog").map(\.id)
    }

    /// Every New action (`new.<kind>.<place>`), kinds in menu order, each kind's places in Fork To's order.
    public static var newPlacementActions: [ActionID] {
        newPlacementGroup.filter { $0.newPlacement != nil }
    }

    /// The New folder's submenus, one per kind (`new.<kind>`).
    public static var newPlacementSubmenus: [ActionID] {
        newPlacementGroup.filter { $0.rawValue.split(separator: ".").count == 2 }
    }

    /// The kind and place this New action opens (`"browser"`, `"left"`), or nil for another action.
    public var newPlacement: (kind: String, place: String)? {
        let parts = rawValue.split(separator: ".")
        guard parts.count == 3, parts[0] == "new",
              RustActionCatalog.shared.groupOf[self] == "NewPlacementActionCatalog" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}

extension ContextMenuCatalog {
    /// The pane menu's New ▸ kind submenus as one New folder, for another pane menu (the pane's
    /// •••) to show the same rows in the same sections. Nil when the pane menu has none.
    public func newPlacementFolder() -> ContextMenuEntry? {
        let kinds = Set(ActionID.newPlacementSubmenus)
        func found(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
            entries.flatMap { entry -> [ContextMenuEntry] in
                switch entry {
                case .submenu(let id, _) where kinds.contains(id): [entry]
                case .submenu(_, let children), .folder(_, let children), .group(_, let children): found(children)
                case .action, .separator, .choices: []
                }
            }
        }
        let submenus = found(entries(for: .pane))
        return submenus.isEmpty ? nil : .folder(.new, submenus)
    }
}
