#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
    var modelAvailability: MobileTaskModelAvailability {
        guard let selectedTemplate,
              MobileTaskAgentProvider(
                command: selectedTemplate.command
              ) != nil else {
            return MobileTaskModelAvailability(
                template: selectedTemplate,
                discoveredModels: nil
            )
        }
        return MobileTaskModelAvailability(
            template: selectedTemplate,
            discoveredModels: displayedModels
        )
    }

    var availableModels: [MobileTaskAgentModel] {
        var models = modelAvailability.models
        if let selectedModelID,
           !models.contains(where: { $0.id == selectedModelID }) {
            models.append(MobileTaskAgentModel(
                id: selectedModelID,
                displayName: selectedModelID
            ))
        }
        return models
    }

    var selectedModel: MobileTaskAgentModel? {
        guard let selectedModelID else { return nil }
        return modelAvailability.selectedModel(id: selectedModelID)
    }

    func validatedModelID(
        _ id: String?,
        for template: MobileTaskTemplate,
        previouslyValidModelID: String? = nil
    ) -> String? {
        let provider = MobileTaskAgentProvider(command: template.command)
        let discoveredModels = provider.flatMap {
            store.discoveredTaskModels(
                provider: $0,
                macDeviceID: selectedMacDeviceID,
                instanceTag: selectedMacInstanceTag
            )
        }
        return MobileTaskModelAvailability(
            template: template,
            discoveredModels: discoveredModels
        ).validatedModelID(
            id,
            previouslyValidModelID: previouslyValidModelID
        )
    }

    func selectModel(_ id: String?) {
        guard !submissionPhase.disablesRequestEditing else { return }
        // Validate against the exact snapshot rendered in the keyboard dock.
        // The store can finish or replace a refresh while a UIKit Menu is
        // open, but a choice the user can see must remain selectable.
        let validatedID = modelAvailability.validatedModelID(id)
        guard id == nil || validatedID != nil else { return }
        guard selectedModelID != validatedID else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedModelID = validatedID
        }
    }
}
#endif
