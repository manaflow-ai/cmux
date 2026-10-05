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
    static func seed(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        guard services.environment.showcase else {
            return .object(["seeded": .bool(false), "error": .string("launch with --showcase to enable the showcase profile")])
        }
        guard let window = services.windows.active ?? services.windows.controllers.first,
              let pane = window.focusedPane ?? window.content?.panes.values.first else {
            return .object(["seeded": .bool(false), "error": .string("no window or pane is ready")])
        }
        seedWorkspaceSet(services: services, windowID: window.state.id)
        let focus = params["focus"]?.boolValue == true
        if let existing = services.showcase.agentTabs[pane.paneKey], services.agentTabs.isAgentTab(existing) {
            if focus { _ = services.revealTab(existing, intent: .focus) }
        } else {
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "~/code/cmux", draft: "Review the latest changes"))
            let paneKey = pane.paneKey
            pane.openAgentTab(seed: seed, select: focus) { [weak services] key in services?.showcase.agentTabs[paneKey] = key }
            if focus, let nsWindow = window.window { WindowActivation.show(nsWindow, .focus) }
        }
        services.feed.startIfSignedIn()
        seedNotifications(services: services, surface: pane.pane.tabs.first?.surface)
        let workspace = pane.daemon.store.workspace(containing: pane.pane.handle)?.id ?? ""
        return .object([
            "seeded": .bool(true),
            "profile": .string("showcase"),
            "workspace": .string(workspace),
            "pane": .string(pane.paneKey),
            // Null while the store has not yet committed a new agent tab.
            "agent_tab": services.showcase.agentTabs[pane.paneKey].map(CmuxNextSettings.JSONValue.string) ?? .null,
            "feed_items": .number(Double(services.feed.model.confirmed.count)),
            "daemon_workspaces": .number(Double(services.daemon.store.workspaces.count)),
            "window_workspaces": .number(Double(services.windows.registry.members(of: window.state.id).count)),
            "focused": .bool(params["focus"]?.boolValue == true),
            "dense": .bool(params["dense"]?.boolValue == true),
            "scene": params["scene"] ?? .null,
        ])
    }

    /// Populate the real daemon ledger so a showcase capture exercises the
    /// production panel and row layout. Desktop banners stay disabled for
    /// the showcase profile, so this never asks for notification permission.
    private static func seedNotifications(services: AppServices, surface: CmuxNextDaemon.SurfaceID?) {
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
        let workspaces = [
            "cmux-next",
            "docs-site",
            "infra",
        ]
        Task { @MainActor in
            guard let connection = services.daemon.connection else { return }
            for name in workspaces {
                if let existing = services.showcase.workspaces[name], services.machines.workspace(id: existing) != nil {
                    continue
                }
                services.showcase.workspaces[name] = nil
                do {
                    let key = WorkspaceKey.generate()
                    services.windows.claimNew(workspaceID: key.rawValue, window: windowID)
                    let id = try await connection.createWorkspace(name: name, key: key).key.rawValue
                    services.showcase.workspaces[name] = id
                    if let controller = services.windows.controller(for: windowID) {
                        services.windows.claim(workspaceID: id, in: controller.state, select: false)
                    }
                    let seededIDs = Array(services.showcase.workspaces.values)
                    _ = services.windows.moveWorkspaces(seededIDs, toWindow: windowID, select: false)
                    services.windows.reconcileMembership()
                } catch {
                    services.daemon.logger.error("showcase workspace \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
#endif
