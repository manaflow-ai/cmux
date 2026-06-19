import Foundation

/// The web renderer backing a Kanban panel.
///
/// Mirrors ``AgentSessionRendererKind``: the panel hosts a `WKWebView` that
/// loads a bundled HTML shell whose path is resolved from this kind. The board
/// currently ships a single React surface, so there is one case; the enum exists
/// so the coordinator resolves the shell URL through the same code path as the
/// agent-session renderer.
enum KanbanRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react

    var id: String { rawValue }

    /// Bundle-relative path components of the HTML shell for this renderer,
    /// resolved against `Bundle.main.resourceURL`.
    var resourceHTMLPathComponents: [String] {
        switch self {
        case .react:
            return ["markdown-viewer", "webviews-app", "kanban.html"]
        }
    }
}
