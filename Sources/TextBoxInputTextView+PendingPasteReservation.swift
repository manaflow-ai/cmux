import AppKit

extension TextBoxInputTextView {
    @MainActor
    @discardableResult
    func beginPendingPasteReservation(id: UUID) -> Bool {
        guard pendingPasteReservations[id] == nil,
              let textStorage else {
            return false
        }

        let originalRange = selectedRange()
        guard isValidSelectedRange(originalRange) else { return false }

        let originalSelection = attributedString().attributedSubstring(
            from: originalRange
        )
        var markerAttributes = currentTextAttributes()
        markerAttributes[Self.pendingAttachmentUploadPlaceholderAttribute] =
            id.uuidString
        let marker = NSAttributedString(
            string: Self.pendingAttachmentUploadPlaceholderCharacter,
            attributes: markerAttributes
        )
        let stagedSelection = NSRange(
            location: originalRange.location + marker.length,
            length: 0
        )

        performWithoutUndoRegistration {
            textStorage.replaceCharacters(in: originalRange, with: marker)
        }
        pendingPasteReservations[id] = TextBoxPendingPasteReservation(
            originalAttributedSelection: originalSelection,
            originalSelectionRange: originalRange,
            stagedSelectionRange: stagedSelection
        )
        setSelectedRange(stagedSelection)
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        return true
    }

    @MainActor
    @discardableResult
    func commitPendingPasteReservation(
        id: UUID,
        withText insertedText: String
    ) -> Bool {
        guard !insertedText.isEmpty else {
            _ = rollbackPendingPasteReservation(id: id)
            return false
        }
        guard let restored = restorePendingPasteReservationForCommit(id: id)
        else {
            return false
        }

        let insertedLength = (insertedText as NSString).length
        insertText(insertedText, replacementRange: restored.replacementRange)
        restoreSelection(
            restored.selection,
            replacing: restored.replacementRange,
            insertedLength: insertedLength
        )
        return true
    }

    @MainActor
    @discardableResult
    func commitPendingPasteReservation(
        id: UUID,
        with attachments: [TextBoxAttachment]
    ) -> Bool {
        guard !attachments.isEmpty else {
            _ = rollbackPendingPasteReservation(id: id)
            return false
        }
        guard let restored = restorePendingPasteReservationForCommit(id: id)
        else {
            return false
        }

        let lengthBeforeInsertion = attributedString().length
        insertAttachments(
            attachments,
            replacementRange: restored.replacementRange
        )
        let insertedLength = attributedString().length
            - (lengthBeforeInsertion - restored.replacementRange.length)
        restoreSelection(
            restored.selection,
            replacing: restored.replacementRange,
            insertedLength: insertedLength
        )
        return true
    }

    @MainActor
    @discardableResult
    func rollbackPendingPasteReservation(
        id: UUID,
        notifyingTextChange: Bool = true
    ) -> Bool {
        guard let reservation = pendingPasteReservations[id] else {
            return false
        }
        guard let markerRange = pendingAttachmentUploadPlaceholderRange(
            id: id
        ), let textStorage else {
            pendingPasteReservations[id] = nil
            return false
        }

        let selectionBeforeRestore = selectedRange()
        performWithoutUndoRegistration {
            textStorage.replaceCharacters(
                in: markerRange,
                with: reservation.originalAttributedSelection
            )
        }
        pendingPasteReservations[id] = nil
        setSelectedRange(
            adjustedSelectionRange(
                selectionBeforeRestore,
                replacing: markerRange,
                insertedLength: reservation.originalAttributedSelection.length
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        if notifyingTextChange {
            didChangeText()
        }
        return true
    }

    @MainActor
    func rollbackAllPendingPasteReservations(
        notifyingTextChange: Bool
    ) {
        let reservationIDs = pendingPasteReservations.keys.sorted { lhs, rhs in
            let lhsLocation =
                pendingAttachmentUploadPlaceholderRange(id: lhs)?.location
                ?? NSNotFound
            let rhsLocation =
                pendingAttachmentUploadPlaceholderRange(id: rhs)?.location
                ?? NSNotFound
            return lhsLocation > rhsLocation
        }
        var restoredAny = false
        for id in reservationIDs {
            restoredAny =
                rollbackPendingPasteReservation(
                    id: id,
                    notifyingTextChange: false
                ) || restoredAny
        }
        if restoredAny, notifyingTextChange {
            didChangeText()
        }
    }

    @MainActor
    func restorePendingPasteReservations(
        in preservedContent: NSMutableAttributedString
    ) {
        let restorations = pendingPasteReservations.compactMap {
            id,
            reservation -> (NSRange, NSAttributedString)? in
            guard let range = Self.pendingAttachmentUploadPlaceholderRanges(
                in: preservedContent,
                id: id
            ).first else {
                return nil
            }
            return (range, reservation.originalAttributedSelection)
        }.sorted { $0.0.location > $1.0.location }

        for (range, originalSelection) in restorations {
            preservedContent.replaceCharacters(
                in: range,
                with: originalSelection
            )
        }
    }

    @MainActor
    private func restorePendingPasteReservationForCommit(
        id: UUID
    ) -> (replacementRange: NSRange, selection: NSRange)? {
        guard let reservation = pendingPasteReservations[id],
              let markerRange = pendingAttachmentUploadPlaceholderRange(
                id: id
              ),
              let textStorage else {
            pendingPasteReservations[id] = nil
            return nil
        }

        let selectionBeforeRestore = selectedRange()
        performWithoutUndoRegistration {
            textStorage.replaceCharacters(
                in: markerRange,
                with: reservation.originalAttributedSelection
            )
        }
        pendingPasteReservations[id] = nil
        let restoredSelection = adjustedSelectionRange(
            selectionBeforeRestore,
            replacing: markerRange,
            insertedLength: reservation.originalAttributedSelection.length
        )
        setSelectedRange(restoredSelection)
        return (
            NSRange(
                location: markerRange.location,
                length: reservation.originalAttributedSelection.length
            ),
            restoredSelection
        )
    }

    @MainActor
    private func restoreSelection(
        _ selection: NSRange,
        replacing range: NSRange,
        insertedLength: Int
    ) {
        let selectionAfterInsertion: NSRange
        if selection.length == 0,
           range.length == 0,
           selection.location == range.location {
            selectionAfterInsertion = NSRange(
                location: range.location + insertedLength,
                length: 0
            )
        } else {
            selectionAfterInsertion = adjustedSelectionRange(
                selection,
                replacing: range,
                insertedLength: insertedLength
            )
        }
        setSelectedRange(selectionAfterInsertion)
    }

    @MainActor
    private func performWithoutUndoRegistration(_ body: () -> Void) {
        let shouldRestoreUndoRegistration =
            undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
        }
        body()
    }
}
