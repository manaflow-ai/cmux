import AppKit
import CmuxTerminal

extension AppDelegate {
    /// Focused and visible terminal identities that should observe a committed
    /// configuration before offscreen registry traversal begins.
    func prioritizedTerminalSurfaceIdentitiesForConfigurationApply()
        -> [ObjectIdentifier] {
        var result: [ObjectIdentifier] = []
        var seenSurfaces: Set<ObjectIdentifier> = []
        var seenManagers: Set<ObjectIdentifier> = []

        func append(_ surface: TerminalSurface?) {
            guard let surface,
                  GhosttyApp.terminalSurfaceRegistry
                    .isRegistered(surface) else {
                return
            }
            let identity = ObjectIdentifier(surface)
            guard seenSurfaces.insert(identity).inserted else {
                return
            }
            result.append(identity)
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
                ) where panel.hostedView.isVisibleInUI {
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
