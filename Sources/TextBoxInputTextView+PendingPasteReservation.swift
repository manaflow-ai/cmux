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
        supersedePendingPasteReservations(intersecting: originalRange)

        let originalSelection = attributedString().attributedSubstring(
            from: originalRange
        )
        let usesMarker = originalSelection.length > 0
        if usesMarker {
            var markerAttributes = currentTextAttributes()
            markerAttributes[Self.pendingAttachmentUploadPlaceholderAttribute] =
                id.uuidString
            let marker = NSAttributedString(
                string: String(
                    repeating: Self.pendingAttachmentUploadPlaceholderCharacter,
                    count: originalSelection.length
                ),
                attributes: markerAttributes
            )
            performWithoutUndoRegistration {
                textStorage.replaceCharacters(in: originalRange, with: marker)
            }
        }
        let stagedSelection = NSRange(
            location: NSMaxRange(originalRange),
            length: 0
        )

        pendingPasteReservations[id] = TextBoxPendingPasteReservation(
            originalAttributedSelection: originalSelection,
            replacementRange: originalRange,
            usesMarker: usesMarker,
            sequence: reservePendingPasteSequence()
        )
        setSelectedRange(stagedSelection)
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
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
        advanceLaterMarkerlessPasteReservations(
            after: restored.sequence,
            anchoredAt: restored.replacementRange.location,
            insertedLength: insertedLength
        )
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
        advanceLaterMarkerlessPasteReservations(
            after: restored.sequence,
            anchoredAt: restored.replacementRange.location,
            insertedLength: insertedLength
        )
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
        notifyingTextChange: Bool = true,
        markerRangesByID: [UUID: NSRange]? = nil
    ) -> Bool {
        guard let reservation = pendingPasteReservations[id] else {
            return false
        }
        guard reservation.usesMarker else {
            pendingPasteReservations[id] = nil
            if notifyingTextChange {
                didChangeText()
            }
            return true
        }
        guard let textStorage else { return false }
        let markerRange = if let markerRangesByID {
            markerRangesByID[id]
        } else {
            pendingAttachmentUploadPlaceholderRange(id: id)
        }
        guard let markerRange else {
            pendingPasteReservations[id] = nil
            if notifyingTextChange {
                didChangeText()
            }
            return true
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
        let markerRangesByID = pendingPasteMarkerRanges()
        let reservationIDs = pendingPasteReservations.sorted { lhs, rhs in
            let lhsLocation = lhs.value.usesMarker
                ? markerRangesByID[lhs.key]?.location ?? NSNotFound
                : lhs.value.replacementRange.location
            let rhsLocation = rhs.value.usesMarker
                ? markerRangesByID[rhs.key]?.location ?? NSNotFound
                : rhs.value.replacementRange.location
            return lhsLocation > rhsLocation
        }.map(\.key)
        var restoredAny = false
        for id in reservationIDs {
            restoredAny =
                rollbackPendingPasteReservation(
                    id: id,
                    notifyingTextChange: false,
                    markerRangesByID: markerRangesByID
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
        let markerRangesByID = pendingPasteMarkerRanges(
            in: preservedContent
        )
        let restorations = pendingPasteReservations.compactMap {
            id,
            reservation -> (NSRange, NSAttributedString)? in
            guard reservation.usesMarker else { return nil }
            guard let range = markerRangesByID[id] else {
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

        let markerRangesByID = pendingPasteMarkerRanges(in: textStorage)
        let restorations = pendingPasteReservations.compactMap {
            id,
            reservation -> TextBoxPendingPasteEditRestoration? in
            guard let markerRange = markerRangesByID[id],
                  Self.pasteReservationRangesIntersect(
                affectedRange,
                markerRange
            ) else {
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
           NSIntersectionRange(
               affectedRange,
               restorations[0].markerRange
           ).length == affectedRange.length {
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
    func updateMarkerlessPendingPasteReservations(
        for affectedRange: NSRange,
        replacementString: String?
    ) {
        guard let replacementString else { return }
        let insertedLength = (replacementString as NSString).length
        let delta = insertedLength - affectedRange.length
        var cancelledIDs: [UUID] = []
        var updatedReservations: [UUID: TextBoxPendingPasteReservation] = [:]

        for (id, var reservation) in pendingPasteReservations
        where !reservation.usesMarker {
            let anchor = reservation.replacementRange.location
            // An edit beginning at the anchor was issued after the paste
            // command, so the paste must remain ordered before that edit.
            guard affectedRange.location < anchor else { continue }
            if NSMaxRange(affectedRange) > anchor {
                cancelledIDs.append(id)
                continue
            }
            reservation.replacementRange.location = max(0, anchor + delta)
            updatedReservations[id] = reservation
        }

        for (id, reservation) in updatedReservations {
            pendingPasteReservations[id] = reservation
        }
        for id in cancelledIDs {
            activePastePreparationTasks.removeValue(forKey: id)?.cancel()
            pendingPasteReservations[id] = nil
        }
    }

    @MainActor
    private func restorePendingPasteReservationForCommit(
        id: UUID
    ) -> (
        replacementRange: NSRange,
        selection: NSRange,
        sequence: UInt64
    )? {
        guard let reservation = pendingPasteReservations[id] else {
            return nil
        }
        breakUndoCoalescing()
        guard reservation.usesMarker else {
            pendingPasteReservations[id] = nil
            return (
                reservation.replacementRange,
                selectedRange(),
                reservation.sequence
            )
        }
        guard let textStorage else { return nil }
        guard let markerRange = pendingAttachmentUploadPlaceholderRange(
            id: id
        ) else {
            pendingPasteReservations[id] = nil
            didChangeText()
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
            restoredSelection,
            reservation.sequence
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
    private func supersedePendingPasteReservations(
        intersecting selectedRange: NSRange
    ) {
        let selectionBeforeRestore = self.selectedRange()
        let markerRangesByID = pendingPasteMarkerRanges()
        let overlappingIDs = pendingPasteReservations.compactMap {
            id,
            reservation -> (id: UUID, range: NSRange)? in
            let reservedRange = reservation.usesMarker
                ? markerRangesByID[id]
                : reservation.replacementRange
            guard let reservedRange,
                  Self.pasteReservationRangesIntersect(
                    selectedRange,
                    reservedRange
                  ) else {
                return nil
            }
            return (id, reservedRange)
        }.sorted { $0.range.location > $1.range.location }
        for (id, _) in overlappingIDs {
            activePastePreparationTasks.removeValue(forKey: id)?.cancel()
            _ = rollbackPendingPasteReservation(
                id: id,
                notifyingTextChange: false,
                markerRangesByID: markerRangesByID
            )
        }
        if !overlappingIDs.isEmpty {
            setSelectedRange(selectionBeforeRestore)
        }
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
