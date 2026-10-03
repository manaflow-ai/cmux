#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextControl

/// Seeds the deterministic DEBUG showcase in the current app window.
/// `debug.showcase.seed` is intentionally one mutation path shared by the
/// launch argument and capture tooling.
@MainActor
enum DebugShowcase {
    static func seed(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard services.environment.showcase else {
            return .object(["seeded": .bool(false), "error": .string("launch with --showcase to enable the showcase profile")])
        }
        guard let window = services.windows.active ?? services.windows.controllers.first,
              let pane = window.focusedPane ?? window.content?.panes.values.first else {
            return .object(["seeded": .bool(false), "error": .string("no window or pane is ready")])
        }
        seedWorkspaceSet(services: services, windowID: window.state.id)
        let key: String
        if let existing = services.showcaseAgentTabs[pane.paneKey] {
            key = existing
        } else {
            key = services.agentTabs.open(
                in: pane.paneKey,
                of: pane.daemon.store,
                seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "~/code/cmux", draft: "Review the latest changes"))
            )
            services.showcaseAgentTabs[pane.paneKey] = key
        }
        if params["focus"]?.boolValue == true {
            pane.showAgentTab(key)
            WindowActivation.show(window.window, .focus)
        }
        services.feed.startIfSignedIn()
        let workspace = pane.daemon.store.workspace(containing: pane.pane.handle)?.id ?? ""
        return .object([
            "seeded": .bool(true),
            "profile": .string("showcase"),
            "workspace": .string(workspace),
            "pane": .string(pane.paneKey),
            "agent_tab": .string(key),
            "feed_items": .number(Double(services.feed.model.confirmed.count)),
            "focused": .bool(params["focus"]?.boolValue == true),
        ])
    }

    /// Adds a small, repeatable local rail for captures. These are ordinary
    /// workspaces, so the sidebar and workspace selection exercise their real
    /// models instead of a showcase-only view.
    private static func seedWorkspaceSet(services: AppServices, windowID: String) {
        let workspaces: [(String, String)] = [
            ("cmux-next", "~/code/cmux"),
            ("docs-site", "~/code/docs-site"),
            ("infra", "~/code/infra"),
        ]
        for (name, cwd) in workspaces where services.showcaseWorkspaces[name] == nil {
            var spawn = WorkspaceSpawn(cwd: cwd, name: name)
            spawn.onListed = { [weak services] id, _ in services?.showcaseWorkspaces[name] = id }
            Task { @MainActor in
                do {
                    let id = try await services.windows.createWorkspace(spawn, into: windowID)
                    services.showcaseWorkspaces[name] = id
                } catch {
                    services.daemon.logger.error("showcase workspace \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
#endif
