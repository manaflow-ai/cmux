import AppKit
import CmuxTerminal

extension AppDelegate {
    /// Focused and visible terminal lifecycle tokens that should observe a
    /// committed configuration before offscreen registry traversal begins.
    ///
    /// A lifecycle token authenticates one surface-process generation. Unlike
    /// `ObjectIdentifier`, it cannot resolve a newly allocated replacement
    /// surface after a deferred main-actor turn.
    func prioritizedTerminalSurfaceLifecycleIDsForConfigurationApply()
        -> [UUID] {
        var result: [UUID] = []
        var seenSurfaces: Set<UUID> = []
        var seenManagers: Set<ObjectIdentifier> = []

        func append(_ surface: TerminalSurface?) {
            guard let surface,
                  GhosttyApp.terminalSurfaceRegistry
                    .isRegistered(surface) else {
                return
            }
            let lifecycleID = surface.terminalLifecycleId
            guard seenSurfaces.insert(lifecycleID).inserted else {
                return
            }
            result.append(lifecycleID)
        }

        append(
            NSApp.keyWindow?.firstResponder
                .cmuxStrictOwningGhosttyView()?
                .terminalSurface
        )

        func visitTabManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerIdentity = ObjectIdentifier(manager)
            guard seenManagers.insert(managerIdentity).inserted,
                  let workspace = manager.selectedTab else {
                return
            }

            append(
                workspace.focusedTerminalInputTarget()?.panel.surface
            )
            for panelID in workspace.panels.keys {
                for panel in workspace.terminalPanels(
                    projectedFromPanelID: panelID
                ) where panel.surface.isRendererPortalVisible {
                    append(panel.surface)
                }
            }
        }

        func visitDock(_ dock: DockSplitStore?) {
            guard let dock, dock.isVisibleInUI else { return }
            if let focusedPanelID = dock.focusedPanelId,
               dock.panelIsActiveInVisibleDockPane(focusedPanelID),
               let terminal = dock.panels[focusedPanelID] as? TerminalPanel {
                append(terminal.surface)
            }
            for panel in dock.panels.values {
                guard let terminal = panel as? TerminalPanel,
                      dock.panelIsSelectedInVisibleDockPane(terminal.id) else {
                    continue
                }
                append(terminal.surface)
            }
        }

        visitTabManager(tabManager)
        if let tabManager {
            visitDock(existingWindowDock(for: tabManager))
        }
        for context in mainWindowContexts.values {
            visitTabManager(context.tabManager)
            visitDock(context.existingWindowDock())
        }
        return result
    }
}
