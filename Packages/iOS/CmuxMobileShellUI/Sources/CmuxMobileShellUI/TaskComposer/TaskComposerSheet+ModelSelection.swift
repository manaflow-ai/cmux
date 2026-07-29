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

    /// Reconciles a hidden model with the Off picker state before submission.
    ///
    /// The restored initial request (and an adopted recovery request) is
    /// cached as already-resolved, so submitting an untouched draft would
    /// skip `makeSubmissionSnapshot` and bypass the `selectedModel` gate.
    /// Marking the request dirty forces resolution through the builder, whose
    /// gate strips the model; `MobileTaskSubmissionIdentity` then mints a
    /// fresh operation ID for the changed bytes (retries of the stripped
    /// request stay idempotent), while completed-operation reconciliation
    /// keeps the originally submitted snapshot.
    func reconcileHiddenModelBeforeSubmission() {
        guard displaySettings.taskComposerModelPickerVariant.renderedVariant == .off,
              selectedModelID != nil else { return }
        submissionIdentity.markRequestDirty()
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
