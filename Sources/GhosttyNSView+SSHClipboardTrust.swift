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
        applySSHClipboardWritePermission(allowed, for: machine)
    }

    /// Applies a trust change to every live host of an SSH terminal. A surface
    /// can be in a workspace panel, a Dock panel, or a restored panel whose
    /// remote projection is still pending; enumerating owners instead of only
    /// catalog projections keeps the current callback policy synchronized in
    /// each case. Newly materialized panes still read the same store at init.
    private func applySSHClipboardWritePermission(
        _ allowed: Bool,
        for machine: SurfaceMachineID
    ) {
        // The menu is opened by this view, so update its surface even when the
        // panel has not entered the catalog yet (the restore/pending case).
        terminalSurface?.setAllowsRemoteClipboardWrites(allowed)

        guard let app = AppDelegate.shared else { return }
        let catalog = SurfaceCatalog.shared

        for workspace in app.mainWindowContexts.values.flatMap({ $0.tabManager.tabs }) {
            for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel })
            where workspace.machineOwningSurface(panel.id, catalog: catalog) == machine {
                panel.surface.setAllowsRemoteClipboardWrites(allowed)
            }
        }

        for dock in DockSplitStore.liveStores {
            for panel in dock.panels.values.compactMap({ $0 as? TerminalPanel })
            where dock.machineOwningSurface(panel.id) == machine {
                panel.surface.setAllowsRemoteClipboardWrites(allowed)
            }
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
