import Foundation

enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .react:
            return String(localized: "agentSession.renderer.react", defaultValue: "React")
        case .solid:
            return String(localized: "agentSession.renderer.solid", defaultValue: "Solid")
        }
    }

    var resourceHTMLPathComponents: [String] {
        switch self {
        case .react:
            return ["markdown-viewer", "webviews-app", "agent-session.html"]
        case .solid:
            return ["agent-session-solid", "index.html"]
        }
    }
}
