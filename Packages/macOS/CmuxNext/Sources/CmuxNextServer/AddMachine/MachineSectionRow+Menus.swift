public import AppKit
public import CmuxNextActions

extension MachineSectionRow {
    /// A row's native menu: New Workspace on This Machine (`row`, disabled while the link is down), or a
    /// joined machine's Check, Rotate Credential and Revoke… (`joined`), run on the row it opened on.
    @MainActor public func menu(_ kind: String, registry: ActionRegistry) -> NSMenu? {
        if kind == "joined", let joined { return joined.menu(rowID: id, registry: registry) }
        guard kind == "row", let item = registry.makeContextMenuItem(for: "workspace.newOnMachine", in: .machineSection,
                                                                     arguments: ["machine": .string(id)]) else { return nil }
        item.title = Self.newWorkspaceTitle
        item.isEnabled = isConnected
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
    }
}

extension JoinedMachine {
    /// A joined machine's "…" menu: the registry's rows for it, run on its id with the row it opened
    /// on (`rowID`, where Check records its result).
    @MainActor public func menu(rowID: String, registry: ActionRegistry) -> NSMenu {
        registry.makeContextMenu(for: .joinedMachine, target: ActionTargetRef(kind: .machine, id: id),
                                 arguments: ["row": .string(rowID)])
    }
}
