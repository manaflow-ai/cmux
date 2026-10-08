import CmuxSSHClipboardTrust
import AppKit
import CmuxSurfaceCatalogModel

extension GhosttyNSView {
    /// Adds the explicit, per-machine permission for an SSH cmux-tui mirror.
    /// The menu action itself is the user gesture that changes the persisted
    /// trust; the resulting grant is limited to OSC 52 writes.
    @discardableResult
    func appendSSHClipboardWriteTrustMenuItem(to menu: NSMenu) -> Bool {
        guard let machine = currentSSHClipboardMachine else { return false }
        let store = sshClipboardWriteTrustStore
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
        let store = sshClipboardWriteTrustStore
        let trusted = !store.isTrusted(machine)
        store.setTrusted(trusted, for: machine)
        applySSHClipboardWritePermission(for: machine)
    }

    /// Applies a trust change to every live host of an SSH terminal. A surface
    /// can be in a workspace panel, a Dock panel, or a restored panel whose
    /// remote projection is still pending; enumerating owners instead of only
    /// catalog projections keeps the current callback policy synchronized in
    /// each case. Newly materialized panes still read the same store at init.
    private func applySSHClipboardWritePermission(for machine: SurfaceMachineID) {
        let allowed = sshClipboardWriteTrustStore.allowsRemoteClipboardWrites(for: machine)
        guard let app = AppDelegate.shared else { return }
        let catalog = SurfaceCatalog.shared
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(
            projections: Array(catalog.projections),
            pendingRestores: catalog.pendingRestoredProjections.projections
        )

        // The menu is opened by this view, so update its surface even when the
        // panel has not entered the catalog yet (the restore/pending case).
        terminalSurface?.setAllowsRemoteClipboardWrites(allowed)

        for workspace in app.mainWindowContexts.values.flatMap({ $0.tabManager.tabs }) {
            workspace.applySSHClipboardWritePermission(for: machine, ownership: ownership)
        }

        for dock in DockSplitStore.liveStores {
            for panel in dock.panels.values.compactMap({ $0 as? TerminalPanel })
            // Reuse the batch ownership index, then preserve Dock's detached
            // transfer fallback without rescanning the catalog per panel.
            where Self.sshClipboardMachine(for: panel, dock: dock, ownership: ownership) == machine {
                panel.surface.setAllowsRemoteClipboardWrites(allowed)
            }
        }
    }

    /// Resolves a Dock terminal through the same ownership path used by
    /// propagation. The catalog index handles projected and pending panels;
    /// the Dock resolver handles detached, transferred, and restored panels
    /// that are live before a projection exists.
    static func sshClipboardMachine(
        for panel: TerminalPanel,
        dock: DockSplitStore,
        ownership: SSHClipboardWriteSurfaceOwnershipIndex
    ) -> SurfaceMachineID? {
        // A local catalog projection can be a placeholder for a Dock panel
        // whose transferred/restored owner is still SSH. Prefer a projected
        // remote machine, then let Dock resolve that local placeholder before
        // falling back to the catalog's local identity.
        if let machine = ownership.machine(for: panel.id), !machine.isLocal {
            return machine
        }
        return dock.machineOwningSurface(panel.id) ?? ownership.machine(for: panel.id)
    }

    private var currentSSHClipboardMachine: SurfaceMachineID? {
        guard let surfaceID = terminalSurface?.id else { return nil }
        let catalog = SurfaceCatalog.shared
        let ownership = SSHClipboardWriteSurfaceOwnershipIndex(
            projections: Array(catalog.projections),
            pendingRestores: catalog.pendingRestoredProjections.projections
        )
        let machine = terminalSurface?.owningWorkspace()?.sshClipboardMachine(
            for: surfaceID,
            ownership: ownership
        ) ?? ownership.machine(for: surfaceID) ?? DockSplitStore.liveStores.lazy.compactMap { dock in
            guard let panelID = dock.panelID(forTerminalLinkSourceID: surfaceID) else {
                return nil
            }
            guard let panel = dock.panels[panelID] as? TerminalPanel else {
                return nil
            }
            return Self.sshClipboardMachine(for: panel, dock: dock, ownership: ownership)
        }.first
        guard let machine, machine.isSSH else {
            return nil
        }
        return machine
    }
}
