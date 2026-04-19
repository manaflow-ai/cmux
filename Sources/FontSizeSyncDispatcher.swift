import AppKit
import Foundation

/// Dispatches terminal font-size changes (increase/decrease/reset) across a
/// configurable scope: focused surface only, all surfaces in the current
/// workspace, or all surfaces across every workspace.
///
/// Broadcasts the delta *action*, not an absolute size, so per-surface font
/// size differences are preserved.
@MainActor
enum FontSizeSyncDispatcher {
    enum Action {
        case increase
        case decrease
        case reset

        var bindingAction: String {
            switch self {
            case .increase: return "increase_font_size:1"
            case .decrease: return "decrease_font_size:1"
            case .reset: return "reset_font_size"
            }
        }
    }

    enum Scope {
        case surface
        case workspace
        case global
    }

    @discardableResult
    static func dispatch(
        _ action: Action,
        scope: Scope,
        tabManager: TabManager?,
        additionalTabManagers: [TabManager] = []
    ) -> Bool {
        guard let tabManager else { return false }

        // Workspace and global scopes are only meaningful when the user
        // pressed the shortcut over a terminal surface. Without this gate
        // a workspace/global binding on e.g. ⌘= would hijack browser zoom
        // whenever a browser pane is focused.
        if scope != .surface && tabManager.selectedWorkspace?.focusedTerminalPanel == nil {
            return false
        }

        let targets = targetPanels(
            scope: scope,
            tabManager: tabManager,
            additionalTabManagers: additionalTabManagers
        )
        guard !targets.isEmpty else { return false }

        var didHandleAny = false
        for panel in targets {
            if panel.performBindingAction(action.bindingAction) {
                didHandleAny = true
            }
        }
        return didHandleAny
    }

    private static func targetPanels(
        scope: Scope,
        tabManager: TabManager,
        additionalTabManagers: [TabManager]
    ) -> [TerminalPanel] {
        switch scope {
        case .surface:
            if let panel = tabManager.selectedWorkspace?.focusedTerminalPanel {
                return [panel]
            }
            return []
        case .workspace:
            guard let workspace = tabManager.selectedWorkspace else { return [] }
            return terminalPanels(in: workspace)
        case .global:
            var seen: Set<ObjectIdentifier> = []
            var managers: [TabManager] = []
            for manager in [tabManager] + additionalTabManagers {
                let id = ObjectIdentifier(manager)
                if seen.insert(id).inserted {
                    managers.append(manager)
                }
            }
            return managers.flatMap { manager in
                manager.tabs.flatMap { terminalPanels(in: $0) }
            }
        }
    }

    private static func terminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        workspace.panels.values.compactMap { $0 as? TerminalPanel }
    }
}
