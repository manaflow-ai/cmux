import SwiftUI
import CmuxSubrouterUI

/// The thin app-target shim mounting the packaged Agents panel with the
/// shared app-owned store (mirrors how `FeedPanelView` reaches its
/// coordinator).
///
/// The right-sidebar shell keeps its content mounted once shown, so the
/// host forwards the sidebar's real visibility: the panel's poll surface
/// must go idle when the sidebar is hidden, not just on unmount.
struct SubrouterAgentsPanelHostView: View {
    let isSidebarVisible: Bool
    /// This window's TabManager; account maintenance actions open their
    /// `sr` commands as new workspaces here.
    let tabManager: TabManager

    var body: some View {
        AgentsPanelView(
            store: SubrouterAppRuntime.shared.store,
            isPanelVisible: isSidebarVisible,
            onVisibilityChange: { visible in
                // Reference-counted through the runtime: each window's
                // panel registers independently, so hiding one window's
                // sidebar cannot stop polling for another window's panel.
                if visible {
                    SubrouterAppRuntime.shared.agentsPanelDidBecomeVisible()
                } else {
                    SubrouterAppRuntime.shared.agentsPanelDidBecomeHidden()
                }
            },
            onOpenTerminal: { [weak tabManager] request in
                // Interactive logins run immediately; destructive commands
                // are pre-typed so Return is the confirmation.
                _ = tabManager?.addWorkspace(
                    title: request.workspaceTitle,
                    initialTerminalInput: request.runsImmediately
                        ? request.command + "\r"
                        : request.command
                )
            }
        )
    }
}
