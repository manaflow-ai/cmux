import Foundation

enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react
    case solid
    case guiMode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .react:
            return String(localized: "agentSession.renderer.react", defaultValue: "React")
        case .solid:
            return String(localized: "agentSession.renderer.solid", defaultValue: "Solid")
        case .guiMode:
            return String(localized: "guiMode.renderer.title", defaultValue: "GUI Mode")
        }
    }

    var resourceHTMLPathComponents: [String] {
        switch self {
        case .react:
            return ["markdown-viewer", "webviews-app", "agent-session.html"]
        case .solid:
            return ["agent-session-solid", "index.html"]
        case .guiMode:
            return ["markdown-viewer", "webviews-app", "gui-mode.html"]
        }
    }
}
