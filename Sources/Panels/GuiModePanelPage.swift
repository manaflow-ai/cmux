import Foundation

/// The route rendered by a GUI Mode agent surface.
enum GuiModePanelPage: String, Codable, Sendable {
    case home
    case taskWorktreePR = "task-worktree-pr"
}
