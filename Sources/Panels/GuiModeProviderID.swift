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
    case qoder

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
        case .qoder:
            return String(localized: "taskManager.agent.qoder", defaultValue: "Qoder")
        }
    }

    var runtimeMode: String {
        switch self {
        case .claude:
            return "native"
        case .codex, .opencode:
            return "native-hooks"
        case .grok, .pi, .omp, .antigravity:
            return "vault-hooks"
        case .amp, .cursor, .gemini, .kiro, .rovodev, .hermesAgent, .copilot, .codebuddy, .factory, .qoder:
            return "hooks"
        }
    }

    var detail: String {
        switch runtimeMode {
        case "native":
            return String(localized: "guiMode.provider.detail.native", defaultValue: "Native cmux session")
        case "native-hooks":
            return String(localized: "guiMode.provider.detail.nativeHooks", defaultValue: "Native session with hook telemetry")
        case "vault-hooks":
            return String(localized: "guiMode.provider.detail.vaultHooks", defaultValue: "Vault-registered hook agent")
        case "hooks":
            return String(localized: "guiMode.provider.detail.hooks", defaultValue: "Hook-backed agent")
        default:
            return String(localized: "guiMode.provider.detail.hooks", defaultValue: "Hook-backed agent")
        }
    }

    var supportLabel: String {
        switch runtimeMode {
        case "native":
            return String(localized: "guiMode.provider.support.native", defaultValue: "Native")
        case "native-hooks":
            return String(localized: "guiMode.provider.support.nativeHooks", defaultValue: "Native + hooks")
        case "vault-hooks":
            return String(localized: "guiMode.provider.support.vaultHooks", defaultValue: "Vault + hooks")
        default:
            return String(localized: "guiMode.provider.support.hooks", defaultValue: "Hooks")
        }
    }

    var setupCommand: String {
        switch self {
        case .claude:
            return "claude auth login"
        default:
            return "cmux hooks \(rawValue) install"
        }
    }

    var taskCommandPreview: String {
        "/task-worktree-pr --provider \(rawValue)"
    }

    var capabilityLabels: [String] {
        var labels: [String] = []
        switch runtimeMode {
        case "native", "native-hooks":
            labels.append(String(localized: "guiMode.provider.capability.nativeSession", defaultValue: "Native session"))
        default:
            break
        }
        if runtimeMode != "native" {
            labels.append(String(localized: "guiMode.provider.capability.hookTelemetry", defaultValue: "Hook telemetry"))
        }
        if isVaultRegistered {
            labels.append(String(localized: "guiMode.provider.capability.vaultRegistry", defaultValue: "Vault registry"))
        }
        if isRestorable {
            labels.append(String(localized: "guiMode.provider.capability.restorable", defaultValue: "Restorable"))
        }
        return labels
    }

    private var isVaultRegistered: Bool {
        switch self {
        case .grok, .pi, .omp, .antigravity:
            return true
        default:
            return false
        }
    }

    private var isRestorable: Bool {
        switch self {
        case .claude, .codex, .opencode, .grok, .pi, .amp, .cursor, .gemini, .kiro, .antigravity,
             .rovodev, .hermesAgent, .copilot, .codebuddy, .factory, .qoder:
            return true
        case .omp:
            return false
        }
    }
}
