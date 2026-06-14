import Foundation

enum GuiModeProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case opencode
    case grok
    case pi
    case omp
    case amp
    case cursor
    case gemini
    case kiro
    case antigravity
    case rovodev
    case hermesAgent = "hermes-agent"
    case copilot
    case codebuddy
    case factory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return String(localized: "agentSession.provider.codex", defaultValue: "Codex")
        case .claude:
            return String(localized: "agentSession.provider.claude", defaultValue: "Claude Code")
        case .opencode:
            return String(localized: "agentSession.provider.opencode", defaultValue: "OpenCode")
        case .grok:
            return String(localized: "taskManager.agent.grok", defaultValue: "Grok")
        case .pi:
            return String(localized: "taskManager.agent.pi", defaultValue: "Pi")
        case .omp:
            return String(localized: "guiMode.provider.omp", defaultValue: "OMP")
        case .amp:
            return String(localized: "taskManager.agent.amp", defaultValue: "Amp")
        case .cursor:
            return String(localized: "taskManager.agent.cursor", defaultValue: "Cursor")
        case .gemini:
            return String(localized: "taskManager.agent.gemini", defaultValue: "Gemini")
        case .kiro:
            return String(localized: "guiMode.provider.kiro", defaultValue: "Kiro")
        case .antigravity:
            return String(localized: "guiMode.provider.antigravity", defaultValue: "Antigravity")
        case .rovodev:
            return String(localized: "taskManager.agent.rovodev", defaultValue: "Rovo Dev")
        case .hermesAgent:
            return String(localized: "taskManager.agent.hermesAgent", defaultValue: "Hermes Agent")
        case .copilot:
            return String(localized: "taskManager.agent.copilot", defaultValue: "Copilot")
        case .codebuddy:
            return String(localized: "taskManager.agent.codebuddy", defaultValue: "CodeBuddy")
        case .factory:
            return String(localized: "taskManager.agent.factory", defaultValue: "Factory")
        }
    }

    var runtimeMode: String {
        switch self {
        case .codex, .claude, .opencode:
            return "native"
        case .grok, .gemini, .kiro, .antigravity, .rovodev, .hermesAgent, .copilot, .codebuddy, .factory:
            return "hooks"
        case .pi, .omp, .amp, .cursor:
            return "plugin"
        }
    }

    var detail: String {
        switch runtimeMode {
        case "native":
            return String(localized: "guiMode.provider.detail.native", defaultValue: "Native cmux session")
        case "hooks":
            return String(localized: "guiMode.provider.detail.hooks", defaultValue: "Hook-backed terminal")
        default:
            return String(localized: "guiMode.provider.detail.plugin", defaultValue: "Plugin-backed terminal")
        }
    }
}
