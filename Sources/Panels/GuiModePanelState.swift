import Foundation

/// Persisted GUI Mode state passed between the native panel and its webview.
struct GuiModePanelState: Codable, Equatable, Sendable {
    var page: GuiModePanelPage
    var prompt: String?
    var providerID: GuiModeProviderID
    var modelID: String
    var reasoningEffort: String

    private enum CodingKeys: String, CodingKey {
        case page
        case prompt
        case providerID
        case modelID
        case reasoningEffort
    }

    static let home = GuiModePanelState(
        page: .home,
        prompt: nil,
        providerID: .codex,
        modelID: GuiModeModelCatalog.defaultOption(for: .codex).id,
        reasoningEffort: GuiModeModelCatalog.defaultReasoningEffort
    )

    init(
        page: GuiModePanelPage,
        prompt: String?,
        providerID: GuiModeProviderID,
        modelID: String,
        reasoningEffort: String
    ) {
        self.page = page
        self.prompt = prompt
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }

    static func taskWorktreePR(
        prompt: String,
        providerID: GuiModeProviderID,
        modelID: String? = nil,
        reasoningEffort: String? = nil
    ) -> Self {
        let model = GuiModeModelCatalog.option(provider: providerID, id: modelID)
        Self(
            page: .taskWorktreePR,
            prompt: prompt,
            providerID: providerID,
            modelID: model.id,
            reasoningEffort: GuiModeModelCatalog.normalizedReasoningEffort(
                provider: providerID,
                modelID: model.id,
                requested: reasoningEffort
            )
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decodeIfPresent(GuiModeProviderID.self, forKey: .providerID) ?? .codex
        let model = GuiModeModelCatalog.option(
            provider: provider,
            id: try container.decodeIfPresent(String.self, forKey: .modelID)
        )
        self.init(
            page: try container.decodeIfPresent(GuiModePanelPage.self, forKey: .page) ?? .home,
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt),
            providerID: provider,
            modelID: model.id,
            reasoningEffort: GuiModeModelCatalog.normalizedReasoningEffort(
                provider: provider,
                modelID: model.id,
                requested: try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            )
        )
    }

}

extension GuiModePanelState {
    init(snapshot: SessionAgentSessionPanelSnapshot) {
        let provider = snapshot.guiModeProviderID ?? .codex
        let model = GuiModeModelCatalog.option(provider: provider, id: snapshot.guiModeModelID)
        self.init(
            page: snapshot.guiModePage ?? .home,
            prompt: snapshot.guiModePrompt,
            providerID: provider,
            modelID: model.id,
            reasoningEffort: GuiModeModelCatalog.normalizedReasoningEffort(
                provider: provider,
                modelID: model.id,
                requested: snapshot.guiModeReasoningEffort
            )
        )
    }
}
