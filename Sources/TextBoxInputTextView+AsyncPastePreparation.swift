import AppKit
import CmuxTerminal

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
        using preparationService: TerminalImageTransferPreparationService,
        pasteboardService: TerminalPasteboardService = GhosttyApp
            .terminalPasteboard,
        onPrepared: @escaping PreparedPasteHandler
    ) -> Bool {
        let placeholderID = UUID()
        guard beginPendingPasteReservation(id: placeholderID) else {
            return false
        }
        let pasteboardReadLease: TerminalPasteboardReadLease?
        switch pasteboardService.reservePasteboardRead(from: pasteboard) {
        case .unmanaged:
            pasteboardReadLease = nil
        case .reserved(let lease):
            pasteboardReadLease = lease
        case .rejected:
            _ = rollbackPendingPasteReservation(
                id: placeholderID,
                notifyingTextChange: true
            )
            return false
        }
        let validationToken = pendingAttachmentUploadValidationToken()

        let task = Task { @MainActor [weak self] in
            defer { pasteboardReadLease?.finish() }
            if let pasteboardReadLease {
                guard await pasteboardReadLease.waitUntilReady(),
                      !Task.isCancelled else {
                    if let self {
                        activePastePreparationTasks[placeholderID] = nil
                        _ = rollbackPendingPasteReservation(
                            id: placeholderID,
                            notifyingTextChange: false
                        )
                    }
                    return
                }
            }
            guard !Task.isCancelled else {
                if let self {
                    activePastePreparationTasks[placeholderID] = nil
                    _ = rollbackPendingPasteReservation(
                        id: placeholderID,
                        notifyingTextChange: false
                    )
                }
                return
            }
            let request = TerminalPasteboardReadRequest(
                pasteboard: pasteboard
            )
            let preparedContent = await preparationService
                .prepareComposer(request: request)
            guard let self else {
                preparationService.cleanupTransferredTemporaryFiles(
                    preparedContent
                )
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
                preparationService.cleanupTransferredTemporaryFiles(
                    preparedContent
                )
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
