import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Locating terminal surfaces and panels
extension AppDelegate {
    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for ws in manager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (route.windowId, ws.id, manager)
                }
            }
        }
        return nil
    }

    /// Resolve the workspace that currently owns a panel/surface ID.
    /// Prefer the provided workspace when available, then fall back to global lookup.
    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, manager)
        }

        if let located = locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, located.tabManager)
        }

        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId) ?? tabManager,
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, manager)
        }

        if let manager = tabManager,
           let workspace = manager.tabs.first(where: {
               $0.panels[panelId] != nil && $0.surfaceIdFromPanelId(panelId) != nil
           }) {
            return (workspace, manager)
        }

        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            let liveSurface = terminalPanel.surface.liveSurfaceForGhosttyAccess(
                reason: "appDelegate.refreshAfterGhosttyConfigReload"
            )
            GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
                to: liveSurface,
                source: source,
                reloadSurfaceConfiguration: { surface, soft, source in
                    GhosttyApp.shared.reloadSurfaceConfiguration(
                        surface,
                        soft: soft,
                        source: source,
                        preferredColorScheme: preferredColorScheme
                    )
                },
                applySurfaceColorScheme: {
                    terminalPanel.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                        preferredColorScheme: preferredColorScheme
                    )
                },
                refreshHostBackground: {
                    terminalPanel.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                },
                forceRefresh: { reason in
                    terminalPanel.surface.forceRefresh(reason: reason)
                }
            )
            refreshedCount += 1
        }
#if DEBUG
        cmuxDebugLog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
#endif
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []

        func visitManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    body(terminalPanel)
                }
            }
        }

        visitManager(tabManager)
        for context in mainWindowContexts.values {
            visitManager(context.tabManager)
        }
    }

}
