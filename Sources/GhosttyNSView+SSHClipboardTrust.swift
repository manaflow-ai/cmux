import AppKit
import CmuxSurfaceCatalogModel

extension GhosttyNSView {
    /// Adds the explicit, per-machine permission for an SSH cmux-tui mirror.
    /// The menu action itself is the user gesture that changes the persisted
    /// trust; the resulting grant is limited to OSC 52 writes.
    @discardableResult
    func appendSSHClipboardWriteTrustMenuItem(to menu: NSMenu) -> Bool {
        guard let machine = currentSSHClipboardMachine else { return false }
        let store = SSHClipboardWriteTrustStore.shared
        let item = menu.addItem(
            withTitle: String(
                localized: "terminalContextMenu.allowSSHClipboardWrites",
                defaultValue: "Allow SSH Machine to Write Clipboard"
            ),
            action: #selector(toggleSSHClipboardWriteTrust(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = store.isTrusted(machine) ? .on : .off
        item.toolTip = String(
            localized: "terminalContextMenu.allowSSHClipboardWrites.tooltip",
            defaultValue: "Allows OSC 52 clipboard writes from this SSH machine. Clipboard reads remain blocked."
        )
        item.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
        return true
    }

    @objc private func toggleSSHClipboardWriteTrust(_ sender: NSMenuItem) {
        guard let machine = currentSSHClipboardMachine else { return }
        let store = SSHClipboardWriteTrustStore.shared
        let trusted = !store.isTrusted(machine)
        store.setTrusted(trusted, for: machine)
        let allowed = store.allowsRemoteClipboardWrites(for: machine)

        // Existing projections must observe revocation immediately. Newly
        // materialized panes read the same store in their construction path.
        for projection in SurfaceCatalog.shared.projections
        where projection.resource.machine == machine {
            guard let workspace = Workspace.liveWorkspace(id: projection.workspaceID),
                  let panel = workspace.panels[projection.panelID] as? TerminalPanel else {
                continue
            }
            panel.surface.setAllowsRemoteClipboardWrites(allowed)
        }
    }

    private var currentSSHClipboardMachine: SurfaceMachineID? {
        guard let surfaceID = terminalSurface?.id,
              let machine = SurfaceCatalog.shared.machineOwningPanel(surfaceID),
              machine.isSSH else {
            return nil
        }
        return machine
    }
}
