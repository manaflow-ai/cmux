#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings

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
        if let existing = services.showcase.agentTabs[pane.paneKey] {
            key = existing
        } else {
            key = services.agentTabs.open(
                in: pane.paneKey,
                of: pane.daemon.store,
                seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "~/code/cmux", draft: "Review the latest changes"))
            )
            services.showcase.agentTabs[pane.paneKey] = key
        }
        if params["focus"]?.boolValue == true {
            pane.showAgentTab(key)
            if let nsWindow = window.window { WindowActivation.show(nsWindow, .focus) }
        }
        services.feed.startIfSignedIn()
        seedNotifications(services: services, surface: pane.pane.tabs.first?.surface)
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

    /// Populate the real daemon ledger so a showcase capture exercises the
    /// production panel and row layout. Desktop banners stay disabled for
    /// the showcase profile, so this never asks for notification permission.
    private static func seedNotifications(services: AppServices, surface: SurfaceID?) {
        guard !services.showcase.notificationsSeeded, services.daemon.connection != nil else { return }
        services.showcase.notificationsSeeded = true
        let entries: [(String, String, NotificationLevel)] = [
            ("Codex finished reviewing #17165", "The GitHub inbox source is ready for a follow-up pass.", .info),
            ("Claude Code needs your input", "Choose whether to keep the local adapter off by default.", .warning),
            ("Fleet build completed", "The capture artifact is ready for a dense UI review.", .info),
        ]
        services.daemon.send("showcase notifications") { connection in
            for (title, body, level) in entries {
                _ = try await connection.notify(title: title, body: body, level: level, surface: surface, source: "agent")
            }
        }
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
        for (name, cwd) in workspaces where services.showcase.workspaces[name] == nil {
            var spawn = WorkspaceSpawn(cwd: cwd, name: name)
            spawn.onListed = { [weak services] id, _ in services?.showcase.workspaces[name] = id }
            Task { @MainActor in
                do {
                    let id = try await services.windows.createWorkspace(spawn, into: windowID)
                    services.showcase.workspaces[name] = id
                } catch {
                    services.daemon.logger.error("showcase workspace \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
#endif
