import AppKit

// Starter prompts use the composer's normal send path, including its owner and refusal handling.
extension HomeNativeTranscriptView {
    public func setFirstRunStarters(_ context: HomeStarterContext) {
        firstRun.starters.setPrompts(context.prompts)
        firstRun.needsLayout = true
        updateStarterAvailability()
    }

    func updateStarterAvailability() {
        firstRun.starters.isEnabled = isSendEnabled && !stopped && !starterSent && starterIntakes == 0 && !transcript.isRestoringDraftAttachments && transcript.draftText.isEmpty
            && transcript.draftAttachments.isEmpty && drop.pending == 0
    }

    func sendStarter(_ prompt: String) {
        updateStarterAvailability()
        guard !firstRun.isHiddenOrHasHiddenAncestor, firstRun.starters.isEnabled,
              firstRun.starters.prompts.contains(prompt) else { return }
        transcript.setDraft(prompt)
        // The draft remains available if the owner cannot accept it. A typed draft or attachment
        // is never replaced or included in a suggestion's send.
        starterSent = true
        if transcript.sendDraft() != nil { starterSent = false }
        updateStarterAvailability()
    }
}
