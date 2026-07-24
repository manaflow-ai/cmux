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
        guard let textStorage else { return false }
        guard let markerRange = pendingAttachmentUploadPlaceholderRange(
            id: id
        ) else {
            return restorePendingPasteReservationWithoutMarker(
                id: id,
                reservation: reservation,
                in: textStorage,
                notifyingTextChange: notifyingTextChange
            )
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

    /// Cancels reservations touched by an AppKit edit before their markers can be deleted.
    @MainActor
    func handleTextChangeTouchingPendingPasteReservation(
        in affectedRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString,
              let textStorage else {
            return false
        }

        let restorations = pendingPasteReservations.compactMap {
            id,
            reservation -> TextBoxPendingPasteEditRestoration? in
            guard let markerRange = pendingAttachmentUploadPlaceholderRange(
                id: id
            ), NSIntersectionRange(markerRange, affectedRange).length > 0 else {
                return nil
            }
            return TextBoxPendingPasteEditRestoration(
                id: id,
                markerRange: markerRange,
                originalSelection: reservation.originalAttributedSelection
            )
        }.sorted { $0.markerRange.location < $1.markerRange.location }
        guard !restorations.isEmpty else { return false }

        let restoredEditRange = Self.editRange(
            affectedRange,
            afterApplying: restorations
        )
        for restoration in restorations.reversed() {
            activePastePreparationTasks.removeValue(
                forKey: restoration.id
            )?.cancel()
            pendingPasteReservations[restoration.id] = nil
            performWithoutUndoRegistration {
                textStorage.replaceCharacters(
                    in: restoration.markerRange,
                    with: restoration.originalSelection
                )
            }
        }
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()

        if replacementString.isEmpty,
           restorations.count == 1,
           affectedRange == restorations[0].markerRange {
            setSelectedRange(restoredEditRange)
            didChangeText()
            return true
        }

        insertText(
            replacementString,
            replacementRange: restoredEditRange
        )
        return true
    }

    @MainActor
    private func restorePendingPasteReservationForCommit(
        id: UUID
    ) -> (replacementRange: NSRange, selection: NSRange)? {
        guard let reservation = pendingPasteReservations[id],
              let textStorage else {
            return nil
        }
        guard let markerRange = pendingAttachmentUploadPlaceholderRange(
            id: id
        ) else {
            _ = restorePendingPasteReservationWithoutMarker(
                id: id,
                reservation: reservation,
                in: textStorage,
                notifyingTextChange: true
            )
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
    private func restorePendingPasteReservationWithoutMarker(
        id: UUID,
        reservation: TextBoxPendingPasteReservation,
        in textStorage: NSTextStorage,
        notifyingTextChange: Bool
    ) -> Bool {
        let restoreLocation = min(
            reservation.originalSelectionRange.location,
            textStorage.length
        )
        let restoreRange = NSRange(location: restoreLocation, length: 0)
        performWithoutUndoRegistration {
            textStorage.replaceCharacters(
                in: restoreRange,
                with: reservation.originalAttributedSelection
            )
        }
        pendingPasteReservations[id] = nil
        setSelectedRange(
            NSRange(
                location: restoreLocation,
                length: reservation.originalAttributedSelection.length
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        if notifyingTextChange {
            didChangeText()
        }
        return true
    }

    private static func editRange(
        _ range: NSRange,
        afterApplying restorations: [TextBoxPendingPasteEditRestoration]
    ) -> NSRange {
        let start = translatedEditBoundary(
            range.location,
            through: restorations,
            useRestoredEndInsideMarker: false
        )
        let end = translatedEditBoundary(
            NSMaxRange(range),
            through: restorations,
            useRestoredEndInsideMarker: true
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func translatedEditBoundary(
        _ boundary: Int,
        through restorations: [TextBoxPendingPasteEditRestoration],
        useRestoredEndInsideMarker: Bool
    ) -> Int {
        var offset = 0
        for restoration in restorations {
            let markerRange = restoration.markerRange
            if boundary <= markerRange.location {
                break
            }
            if boundary >= NSMaxRange(markerRange) {
                offset += restoration.originalSelection.length
                    - markerRange.length
                continue
            }
            return markerRange.location + offset
                + (useRestoredEndInsideMarker
                    ? restoration.originalSelection.length
                    : 0)
        }
        return boundary + offset
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
