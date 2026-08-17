#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel

extension TaskComposerSheet {
    var modelAvailability: MobileTaskModelAvailability {
        guard let selectedTemplate,
              MobileTaskAgentProvider(
                command: selectedTemplate.command
              ) != nil else {
            return MobileTaskModelAvailability(
                template: selectedTemplate,
                discoveredModels: nil,
                defaultModel: nil
            )
        }
        return MobileTaskModelAvailability(
            template: selectedTemplate,
            discoveredModels: displayedModels,
            defaultModel: displayedDefaultModel
        )
    }

    var availableModels: [MobileTaskAgentModel] {
        var models = modelAvailability.models
        if let selectedModelID,
           !models.contains(where: { $0.id == selectedModelID }) {
            if let explicitlySelectedModel,
               explicitlySelectedModel.id == selectedModelID {
                models.append(explicitlySelectedModel)
            } else {
                models.append(MobileTaskAgentModel(
                    id: selectedModelID,
                    displayName: selectedModelID
                ))
            }
        }
        return models
    }

    var selectedModel: MobileTaskAgentModel? {
        guard let selectedModelID else { return nil }
        // Once a user chooses from a presented menu, that concrete selection
        // owns the request until they change it. A later catalog replacement
        // can change the available choices, but must not silently strip the
        // already-visible model from submission.
        return availableModels.first { $0.id == selectedModelID }
    }

    var availableEfforts: [MobileTaskAgentEffort] {
        selectedModel?.efforts ?? modelAvailability.defaultModel?.efforts ?? []
    }

    var effortDefaultModel: MobileTaskAgentModel? {
        selectedModel ?? modelAvailability.defaultModel
    }

    var selectedEffort: MobileTaskAgentEffort? {
        guard let selectedEffortID else { return nil }
        return availableEfforts.first { $0.id == selectedEffortID }
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

    func selectModel(_ model: MobileTaskAgentModel?) {
        guard !submissionPhase.disablesRequestEditing else { return }
        // TaskComposerModelMenuContent resolves this concrete value from the
        // menu snapshot UIKit presented. It remains authoritative for the tap
        // even if host discovery replaces the live catalog while the menu is
        // open. Draft restoration still uses validatedModelID(_:for:).
        let selectedID = model?.id
        guard selectedModelID != selectedID
            || explicitlySelectedModel != model else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedModelID = selectedID
            explicitlySelectedModel = model
            selectedEffortID = (model ?? modelAvailability.defaultModel)?.defaultEffortID
        }
        store.recordAppEvent(
            .taskModelSelected,
            correlationID: selectedID
        )
    }

    func selectEffort(_ effort: MobileTaskAgentEffort?) {
        guard !submissionPhase.disablesRequestEditing else { return }
        let selectedID = effort?.id
        guard availableEfforts.contains(where: { $0.id == selectedID }),
              selectedEffortID != selectedID else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedEffortID = selectedID
        }
    }

    func reconcileSelectedEffort() {
        let reconciledID: String?
        if availableEfforts.contains(where: { $0.id == selectedEffortID }) {
            reconciledID = selectedEffortID
        } else {
            reconciledID = effortDefaultModel?.defaultEffortID
        }
        guard selectedEffortID != reconciledID else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedEffortID = reconciledID
        }
    }
}
#endif
