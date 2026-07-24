import AppKit

extension TextBoxInputTextView {
    typealias PreparedPasteHandler = @MainActor (
        TextBoxInputTextView,
        UUID,
        UInt64,
        TextBoxPastePreparedContent
    ) -> Void

    /// Reserves the insertion point and starts pasteboard/image preparation off the main actor.
    @MainActor
    @discardableResult
    func beginPreparingPaste(
        from pasteboard: NSPasteboard,
        onPrepared: @escaping PreparedPasteHandler
    ) -> Bool {
        let request = TerminalPasteboardReadRequest(pasteboard: pasteboard)
        let placeholderID = UUID()
        guard beginPendingPasteReservation(id: placeholderID) else {
            return false
        }
        let validationToken = pendingAttachmentUploadValidationToken()
        let service = TextBoxPastePreparationService()

        let task = Task { @MainActor [weak self] in
            let preparedContent = await service.prepare(request: request)
            guard let self else {
                preparedContent.cleanupTransferredTemporaryFiles()
                return
            }
            activePastePreparationTasks[placeholderID] = nil
            guard !Task.isCancelled,
                  canAcceptPendingAttachmentUpload(
                    validationToken: validationToken
                  ) else {
                _ = rollbackPendingPasteReservation(
                    id: placeholderID,
                    notifyingTextChange: false
                )
                preparedContent.cleanupTransferredTemporaryFiles()
                return
            }
            onPrepared(
                self,
                placeholderID,
                validationToken,
                preparedContent
            )
        }
        activePastePreparationTasks[placeholderID] = task
        return true
    }

    @MainActor
    func cancelActivePastePreparations() {
        let tasks = activePastePreparationTasks.values
        activePastePreparationTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }
}
