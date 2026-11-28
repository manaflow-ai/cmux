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
