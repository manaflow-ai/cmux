import Foundation

enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react
    case solid
    case claudeDesktop = "claude-desktop"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .react:
            return String(localized: "agentSession.renderer.react", defaultValue: "React")
        case .solid:
            return String(localized: "agentSession.renderer.solid", defaultValue: "Solid")
        case .claudeDesktop:
            return String(localized: "machines.kind.desktop", defaultValue: "Desktop")
        }
    }

    var resourceHTMLPathComponents: [String] {
        switch self {
        case .react:
            return ["markdown-viewer", "webviews-app", "agent-session.html"]
        case .solid:
            return ["agent-session-solid", "index.html"]
        case .claudeDesktop:
            // The Desktop renderer never loads a bundled web shell. Keep a
            // harmless fallback so this shared renderer descriptor remains total.
            return ["markdown-viewer", "webviews-app", "agent-session.html"]
        }
    }
}
