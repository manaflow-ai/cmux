#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel

extension TaskComposerSheet {
    func persistPickerPreferences() {
        guard store.isSignedIn, store.currentSessionGeneration == sessionGeneration,
              !selectedMacDeviceID.isEmpty, let selectedTemplateID else { return }
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID, instanceTag: selectedMacInstanceTag
        )
        store.taskTemplateStore?.setComposerPickerPreferences(
            MobileTaskComposerPickerPreferences(
                templateID: selectedTemplateID,
                model: selectedModel,
                defaultModel: displayedDefaultModel,
                effortID: selectedEffortID,
                directory: directory,
                didEditDirectory: didEditDirectory,
                workspaceGroupID: selectedWorkspaceGroupID
            ),
            macPairingID: pairingID
        )
        store.taskTemplateStore?.setLastMacDeviceID(pairingID)
    }

    /// Called after changing the Mac identity, before the next model refresh.
    func restorePickerPreferences(templates: [MobileTaskTemplate]) {
        let fallbackTemplateID = selectedTemplateID
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID, instanceTag: selectedMacInstanceTag
        )
        let preferences = store.taskTemplateStore?.composerPickerPreferences(macPairingID: pairingID)
        selectedTemplateID = (preferences?.templateID).flatMap { id in
            templates.contains { $0.id == id } ? id : nil
        } ?? fallbackTemplateID.flatMap { id in
            templates.contains { $0.id == id } ? id : nil
        } ?? store.taskTemplateStore?.lastTemplateID().flatMap { id in
            templates.contains { $0.id == id } ? id : nil
        } ?? templates.first?.id
        let matchingPreferences = preferences?.templateID == selectedTemplateID ? preferences : nil
        selectedModelID = matchingPreferences?.model?.id
        explicitlySelectedModel = matchingPreferences?.model
        selectedEffortID = matchingPreferences?.effortID
        displayedModels = []
        displayedDefaultModel = matchingPreferences?.defaultModel
        displayedModelError = nil
        selectedWorkspaceGroupID = preferences?.workspaceGroupID
        pendingRestoredWorkspaceGroupID = selectedWorkspaceGroupID
        workspaceGroupSelectionRequiresResolution = false
        // A folder chosen on another Mac must never follow the route switch.
        didEditDirectory = preferences?.didEditDirectory ?? false
        if preferences?.didEditDirectory == true, let preferences {
            directory = preferences.directory
        } else {
            syncSuggestedDirectory()
        }
    }
}
#endif
