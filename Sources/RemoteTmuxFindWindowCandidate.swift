import Foundation

/// One mirrored tmux pane that find-window can search, with the names it is known by.
struct RemoteTmuxFindWindowCandidate: Identifiable, Equatable, Sendable {
    /// A pane id is unique only within its tmux server.
    struct ID: Hashable, Sendable {
        let hostKey: String
        let paneId: Int
    }

    let id: ID
    /// The host as shown in the sidebar, for telling hosts apart.
    let hostLabel: String
    let sessionName: String
    let windowId: Int
    /// `#{window_name}`, the mirrored tab's title.
    let windowName: String
    let paneId: Int
    /// The pane's position in its window, from 0.
    let paneIndex: Int
    /// Panes in the window; a window with one pane needs no pane label.
    let windowPaneCount: Int
    /// `#{pane_title}` as tmux has it, host-name default included.
    let paneTitle: String
    /// The pane title unless it is only the host-name default tmux fills in.
    let intentionalPaneTitle: String?
    let workspaceId: UUID
    /// The cmux surface rendering the pane, once it is mounted.
    let surfaceId: UUID?
    /// Tab order across every searched pane, for stable result order.
    let order: Int
}
