import CmuxCloud
import Foundation

/// The verbs a machine offers in every Cloud menu: the sidebar context menu,
/// the status item, and the main-menu Cloud menu. Each surface binds the
/// closures to its own entrypoint; the list, order and capability gates live
/// only here.
struct CloudMachineMenuVerbs {
    var openShell: @MainActor (String) -> Void
    var newWorkspace: @MainActor (String) -> Void
    var openDesktop: @MainActor (String) -> Void
    var runCommand: @MainActor (String, [String]) -> Void
    var promptRename: @MainActor (MachineSnapshot) -> Void
    var copyToPasteboard: @MainActor (String) -> Void
    var confirmDelete: @MainActor (MachineSnapshot) -> Void
    var promptUpgrade: @MainActor () -> Void
    /// Forks through the shared create coordinator, so every surface shows the
    /// same pending "Fork of …" row the moment the person picks Fork.
    var fork: @MainActor (MachineSnapshot) -> Void = { _ in }

    /// Connect verbs: Open Shell, New Workspace, Open Desktop, full client.
    /// A machine past its free window offers only the upgrade.
    func openEntries(_ machine: MachineSnapshot) -> [CloudMenuEntry] {
        let id = machine.id
        if machine.freeAccess == .expired {
            return [action("upgrade", id, String(localized: "machines.menu.upgradeToReconnect", defaultValue: "Upgrade to Reconnect…")) { promptUpgrade() }]
        }
        var entries = [
            action("openShell", id, String(localized: "machines.menu.openShell", defaultValue: "Open Shell")) { openShell(id) },
            action("newWorkspace", id, String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { newWorkspace(id) },
        ]
        if machine.isDesktop {
            entries.append(action("openDesktop", id, String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) { openDesktop(id) })
        }
        entries.append(action("openFullClient", id, String(localized: "cloudTree.menu.openFullClient", defaultValue: "Open Full cmux-tui Client")) { runCommand(id, ["vm", "tui"]) })
        return entries
    }

    /// Rename, Copy IP Address, Status, and the provider-honored Checkpoint/Fork.
    func manageEntries(_ machine: MachineSnapshot) -> [CloudMenuEntry] {
        let id = machine.id
        var entries = [
            action("rename", id, String(localized: "machines.menu.rename", defaultValue: "Rename…")) { promptRename(machine) },
        ]
        if let address = machine.privateAddress {
            entries.append(action("copyIP", id, String(localized: "machines.menu.copyIPAddress", defaultValue: "Copy IP Address")) { copyToPasteboard(address) })
        }
        entries.append(action("status", id, String(localized: "machines.menu.status", defaultValue: "Status")) { runCommand(id, ["vm", "status"]) })
        // Only verbs this provider can honor: a Checkpoint that answers 502 is not a verb.
        if machine.capabilities.snapshot {
            entries.append(action("checkpoint", id, String(localized: "machines.menu.checkpoint", defaultValue: "Checkpoint")) { runCommand(id, ["vm", "snapshot"]) })
        }
        if machine.capabilities.canFork {
            entries.append(action("fork", id, String(localized: "machines.menu.fork", defaultValue: "Fork")) { fork(machine) })
        }
        return entries
    }

    func deleteEntries(_ machine: MachineSnapshot) -> [CloudMenuEntry] {
        let id = machine.id
        return [action("delete", id, String(localized: "machines.menu.delete", defaultValue: "Delete…")) { confirmDelete(machine) }]
    }

    /// The complete machine submenu used outside the sidebar, led by a status line.
    func submenuEntries(_ machine: MachineSnapshot) -> [CloudMenuEntry] {
        var entries: [CloudMenuEntry] = [.header(id: "machine.\(machine.id).summary", title: Self.summary(machine))]
        entries.append(.separator(id: "machine.\(machine.id).sep.open"))
        entries += openEntries(machine)
        entries.append(.separator(id: "machine.\(machine.id).sep.manage"))
        entries += manageEntries(machine)
        entries.append(.separator(id: "machine.\(machine.id).sep.delete"))
        entries += deleteEntries(machine)
        return entries
    }

    /// "Ready · Desktop · noble-wren-id", the machine's state in one line.
    static func summary(_ machine: MachineSnapshot) -> String {
        var parts = [machine.activityLabel, machine.kindLabel]
        switch machine.freeAccess {
        case .unrestricted:
            break
        case .active:
            parts.append(String(localized: "cloudMenu.machine.freeAccess", defaultValue: "Free access"))
        case .expired:
            parts.append(String(localized: "cloudMenu.machine.locked", defaultValue: "Locked"))
        }
        if machine.showsName { parts.append(machine.id) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func action(_ verb: String, _ id: String, _ title: String, perform: @escaping @MainActor () -> Void) -> CloudMenuEntry {
        .action(CloudMenuAction(id: "machine.\(id).\(verb)", title: title, perform: perform))
    }
}
