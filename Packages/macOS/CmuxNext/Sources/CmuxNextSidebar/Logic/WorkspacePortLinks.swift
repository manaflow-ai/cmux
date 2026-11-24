import Foundation

/// The ports a workspace's hover card offers to open, asked of Rust (`cmux-layout-reducer::workspace_port_links`,
/// op `workspace_port_links`, with its tests): one link per port the workspace's `ports` status entry names. Asked
/// once per card show, never per frame or pointer move. Nil when the library did not answer; the card then shows the
/// entry as plain text, as before.
nonisolated struct WorkspacePortLinks: Sendable {
    struct Link: Decodable, Equatable, Sendable {
        let port: Int
        /// What the link reads ("localhost:5173").
        let label: String
        /// What a click opens in a browser tab of the workspace ("http://localhost:5173/").
        let url: String
    }

    func links(_ ports: String) -> [Link]? {
        RustSidebarClient.call("workspace_port_links", ["ports": ports], as: [Link].self)
    }
}
