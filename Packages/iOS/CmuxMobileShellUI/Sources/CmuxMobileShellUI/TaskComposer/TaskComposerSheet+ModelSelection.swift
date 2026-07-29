#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
    var availableModels: [MobileTaskAgentModel] {
        guard let selectedTemplate else { return [] }
        return MobileTaskAgentProvider(command: selectedTemplate.command)?.models ?? []
    }

    var selectedModel: MobileTaskAgentModel? {
        // With the picker Off no model UI is rendered, so a model restored
        // from an earlier draft must not silently ride into snapshots, drafts,
        // or the submitted command. The selection state itself is kept so
        // re-enabling a variant restores the visible choice.
        guard displaySettings.taskComposerModelPickerVariant.renderedVariant != .off,
              let selectedTemplate,
              let selectedModelID else { return nil }
        return MobileTaskAgentProvider(command: selectedTemplate.command)?
            .model(id: selectedModelID)
    }

    /// Applies the Off-variant gate to a resolved submission snapshot.
    ///
    /// The restored initial request (and an adopted recovery request) is
    /// cached as already-resolved, so submitting an untouched draft skips
    /// `makeSubmissionSnapshot` and would bypass the `selectedModel` gate.
    /// This is the single submission-boundary chokepoint: while the picker is
    /// Off, a hidden model captured by any cached request is stripped and the
    /// command recomposed, keeping the same operation identifier.
    func effectiveSubmissionSnapshot(
        _ snapshot: MobileTaskSubmissionSnapshot
    ) -> MobileTaskSubmissionSnapshot {
        guard displaySettings.taskComposerModelPickerVariant.renderedVariant == .off,
              snapshot.modelID != nil,
              let selectedTemplate,
              selectedTemplate.id == snapshot.templateID else {
            return snapshot
        }
        return MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: snapshot.prompt,
            modelID: nil,
            macDeviceID: snapshot.macDeviceID,
            directory: snapshot.directory,
            workspaceName: snapshot.workspaceName,
            didEditDirectory: snapshot.didEditDirectory,
            operationID: snapshot.operationID
        )
    }

    func selectModel(_ id: String?) {
        guard !submissionPhase.disablesRequestEditing else { return }
        let validatedID: String?
        if let id {
            guard let selectedTemplate,
                  MobileTaskAgentProvider(command: selectedTemplate.command)?
                      .model(id: id) != nil else { return }
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
