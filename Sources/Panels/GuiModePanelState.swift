import Foundation

/// Persisted GUI Mode state passed between the native panel and its webview.
struct GuiModePanelState: Codable, Equatable, Sendable {
    var page: GuiModePanelPage
    var prompt: String?
    var providerID: GuiModeProviderID

    static let home = GuiModePanelState(page: .home, prompt: nil, providerID: .codex)

    static func taskWorktreePR(prompt: String, providerID: GuiModeProviderID) -> Self {
        Self(page: .taskWorktreePR, prompt: prompt, providerID: providerID)
    }

}

extension GuiModePanelState {
    init(snapshot: SessionAgentSessionPanelSnapshot) {
        self.init(page: snapshot.guiModePage ?? .home, prompt: snapshot.guiModePrompt, providerID: snapshot.guiModeProviderID ?? .codex)
    }
}
