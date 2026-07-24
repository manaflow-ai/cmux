#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
    var availableModels: [MobileTaskAgentModel] {
        guard let selectedTemplate else { return [] }
        return MobileTaskAgentModelCatalog.models(forCommand: selectedTemplate.command)
    }

    var selectedModel: MobileTaskAgentModel? {
        guard let selectedTemplate,
              let selectedModelID else { return nil }
        return MobileTaskAgentModelCatalog.model(
            id: selectedModelID,
            forCommand: selectedTemplate.command
        )
    }

    func selectModel(_ id: String?) {
        guard !submissionPhase.disablesRequestEditing else { return }
        let validatedID: String?
        if let id {
            guard let selectedTemplate,
                  MobileTaskAgentModelCatalog.model(
                      id: id,
                      forCommand: selectedTemplate.command
                  ) != nil else { return }
            validatedID = id
        } else {
            validatedID = nil
        }
        guard selectedModelID != validatedID else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedModelID = validatedID
        }
    }
}
#endif
