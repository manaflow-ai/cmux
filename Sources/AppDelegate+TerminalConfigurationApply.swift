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

        func visit(_ manager: TabManager?) {
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

        visit(tabManager)
        for context in mainWindowContexts.values {
            visit(context.tabManager)
        }
        return result
    }
}
