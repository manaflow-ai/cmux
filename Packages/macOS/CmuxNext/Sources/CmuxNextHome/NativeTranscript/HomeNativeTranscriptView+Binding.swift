public import CmuxHomeRender

/// The one place a host connects this view's composer to its bound store:
/// attachments (paste, drop, the picker) prepare through the store, refusals
/// show in the composer notice, and Cancel Upload reaches the store. The app
/// (`HomeHostView`) and the DEBUG fixture both call it, so no host can leave
/// attachments unwired.
extension HomeNativeTranscriptView {
    public func connect(_ binding: HomeStoreBinding) {
        attachmentPreparer = binding.store
        binding.onAttachmentRefusal = { [weak self] _, refusal in self?.showAttachmentRefusal(refusal) }
        binding.onRefusal = { [weak self] _, rejection in self?.showRefusal(rejection) }
        binding.onSendNotDelivered = { [weak self] _, rejection in self?.showNotDelivered(rejection) }
        onCancelSend = { [weak binding] key in binding?.cancelSend(key) ?? false }
    }
}
