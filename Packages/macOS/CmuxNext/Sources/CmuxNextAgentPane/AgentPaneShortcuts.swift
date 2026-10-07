public import CmuxNextActions
import Foundation

/// The app shortcuts the agent page shows in its tooltips and keycaps, as the
/// user bound them (Settings, `cmux.json`), keyed by action id. Actions with
/// no shortcut are left out, so the page shows none.
public nonisolated struct AgentPaneShortcuts: Equatable, Sendable {
    /// The actions the page names. Copy Tab Link on an agent tab copies its
    /// chat's link, so the page's Copy chat link shows that shortcut.
    static let actions: [ActionID] = [
        "agentPane.searchChats", "palette.newAgentChat", "palette.toggleDictation",
        "agentPane.permission.allowOnce", "agentPane.permission.allowChat", "agentPane.permission.deny",
        "agentPane.permission.expand", "agentPane.permission.retry", "agentPane.permission.revoke",
        "agentPane.permission.refresh", "palette.copySurfaceLink",
        // The chat header's tools and "..." menu (AgentPaneModel.headerActions).
        "splitRight", "splitBrowserRight", "renameTab", "palette.toggleTabPin",
        "moveSurfaceToPaneRight", "palette.moveTabToNewWorkspace", "closeTab",
    ]

    public var labels: [String: String] = [:]

    public init(labels: [String: String] = [:]) {
        self.labels = labels
    }

    /// `registry`'s current bindings for ``actions``. Read inside
    /// `Observations` it tracks rebinds.
    @MainActor public static func read(_ registry: ActionRegistry) -> AgentPaneShortcuts {
        var labels: [String: String] = [:]
        for id in actions {
            if let display = registry.shortcutDisplay(for: id) { labels[id.rawValue] = display }
        }
        return AgentPaneShortcuts(labels: labels)
    }

    /// The script that hands ``labels`` to a loaded page.
    func script() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.cmuxAcpmuxBridge?.applyShortcuts?.(\(json));"
    }
}
