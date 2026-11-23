import Foundation

/// The agents' own browser workspace: where `browser.page.right` opens an
/// agent's tab when Home has no column right of the chat
/// (``BrowserAgentWorkspaceHost``). One workspace in Home's session holds
/// every agent's tab (each agent keeps to its own, by lease); it is an
/// ordinary sidebar row (no hidden workspaces: Aziz, 2026-11-11), made without
/// focus, so the person's window, workspace and Home layout stay as they were.
struct BrowserAgentWorkspace: Sendable, Equatable {
    /// The workspace's fixed durable key, so a renamed workspace is still found.
    static let key = BrowserPageService.agentWorkspaceKey

    var workspace: ControlWorkspaceInfo

    /// The workspace's name when it is made.
    static var name: String { ControlStrings.text("control.browser.agentWorkspaceName", "Agent browser") }

    /// The agents' workspace: in `session` (Home's) first, by its key, else by its name; nil when none.
    static func resolve(in topology: ControlTopology, session: String?) -> Self? {
        let ordered = topology.workspaces.filter { $0.sessionID == session } + topology.workspaces.filter { $0.sessionID != session }
        if let keyed = ordered.first(where: { workspaceKeyForm($0.id) == workspaceKeyForm(key) }) { return Self(workspace: keyed) }
        return ordered.first { $0.kind == nil && $0.name == name }.map(Self.init(workspace:))
    }

    /// Its browser tabs, in strip order. Every one is an agent's: the workspace is theirs, and a
    /// daemon-made tab may report its profile as `default` before the app's record arrives.
    var agentTabs: [ControlTabInfo] {
        workspace.panes.flatMap(\.tabs).filter { $0.kind == "browser" && $0.page == nil }
    }

    /// The pane holding `tab`.
    func pane(of tab: String) -> ControlPaneInfo? {
        workspace.panes.first { $0.tabs.contains { $0.id == tab } }
    }

    /// Every browser tab outside Home's workspace: where an agent's own tab is looked for when
    /// Home has no right column, so it is found whatever the agents' workspace is called now.
    static func browserTabs(outside home: ControlWorkspaceInfo, in topology: ControlTopology) -> Set<String> {
        Set(topology.workspaces.lazy.filter { $0.id != home.id }.flatMap(\.panes).flatMap(\.tabs)
            .filter { $0.kind == "browser" && $0.page == nil }.map(\.id))
    }
}
