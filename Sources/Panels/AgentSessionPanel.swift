import AppKit
import Foundation

enum GuiModePanelPage: String, Sendable {
    case home
    case taskWorktreePR = "task-worktree-pr"
}

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

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    let workingDirectory: String?
    let rendererSession = AgentSessionWebRendererSession()
    private(set) var guiModePage: GuiModePanelPage
    private(set) var guiModePrompt: String?
    private(set) var guiModeProviderID: GuiModeProviderID

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    var displayIcon: String? { "sparkles.rectangle.stack" }
    private(set) var isDirty: Bool = false
    var onDisplayStateChanged: ((String, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, isDirty)
        }
    }

    init(
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID = .codex,
        workingDirectory: String? = nil,
        guiModePage: GuiModePanelPage = .home,
        guiModePrompt: String? = nil,
        guiModeProviderID: GuiModeProviderID = .codex
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.guiModePage = guiModePage
        self.guiModePrompt = guiModePrompt
        self.guiModeProviderID = guiModeProviderID
        self.displayTitle = Self.title(provider: initialProviderID, rendererKind: rendererKind)
        self.rendererSession.onHasActiveProviderChanged = { [weak self] hasActiveProvider in
            self?.setHasActiveProvider(hasActiveProvider)
        }
        self.rendererSession.onProviderIDChanged = { [weak self] providerID in
            self?.setCurrentProviderID(providerID)
        }
    }

    nonisolated static func title(
        provider: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind
    ) -> String {
        if rendererKind == .guiMode {
            return String(localized: "guiMode.panel.title", defaultValue: "GUI Mode")
        }
        let format = String(localized: "agentSession.panel.title", defaultValue: "%@ · %@")
        return String(format: format, provider.displayName, rendererKind.displayName)
    }

    func focus() {
        rendererSession.focus()
    }

    func unfocus() {
        rendererSession.unfocus()
    }

    func close() {
        rendererSession.close()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func configureGuiModeTask(prompt: String, providerID: GuiModeProviderID) {
        guard rendererKind == .guiMode else { return }
        guiModePage = .taskWorktreePR
        guiModePrompt = prompt
        guiModeProviderID = providerID
        displayTitle = String(localized: "guiMode.task.panel.title", defaultValue: "/task-worktree-pr")
        emitDisplayStateChanged()
    }

    private func setHasActiveProvider(_ hasActiveProvider: Bool) {
        guard isDirty != hasActiveProvider else { return }
        isDirty = hasActiveProvider
        emitDisplayStateChanged()
    }

    private func setCurrentProviderID(_ providerID: AgentSessionProviderID) {
        guard currentProviderID != providerID else { return }
        currentProviderID = providerID
        displayTitle = Self.title(provider: providerID, rendererKind: rendererKind)
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
