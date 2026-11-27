public import AppKit
public import CmuxNextActions

extension JoinedMachine {
    /// A joined machine's "…" menu: the registry's rows for it, run on its id with the row it opened
    /// on (`rowID`, where Check records its result).
    @MainActor public func menu(rowID: String, registry: ActionRegistry) -> NSMenu {
        registry.makeContextMenu(for: .joinedMachine, target: ActionTargetRef(kind: .machine, id: id),
                                 arguments: ["row": .string(rowID)])
    }
}

extension JoinedMachineAction {
    /// The registered action of a joined machine's menu row (`JoinedMachineActionCatalog`).
    public var actionID: ActionID { ActionID(rawValue: "machine.joined.\(rawValue)") }
}
