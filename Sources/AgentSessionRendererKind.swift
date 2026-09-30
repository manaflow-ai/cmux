import Foundation
import CmuxSettings

enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case native
    case typescript
    case react
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native:
            return String(localized: "agentSession.renderer.native", defaultValue: "Native")
        case .typescript:
            return String(localized: "agentSession.renderer.typescript", defaultValue: "TypeScript")
        case .react:
            return String(localized: "agentSession.renderer.react", defaultValue: "React")
        case .solid:
            return String(localized: "agentSession.renderer.solid", defaultValue: "Solid")
        }
    }

    var resourceHTMLPathComponents: [String] {
        switch self {
        case .native, .typescript:
            return []
        case .react:
            return ["markdown-viewer", "webviews-app", "agent-session.html"]
        case .solid:
            return ["agent-session-solid", "index.html"]
        }
    }

    static func configured() -> Self {
        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        return store.snapshotValue(for: SettingCatalog().app.agentSessionRenderer) == "typescript"
            ? .typescript
            : .native
    }
}
