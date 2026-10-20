import AppKit

extension TextBoxInputTextView {
    @MainActor
    func pendingPasteMarkerRanges(
        in attributed: NSAttributedString? = nil
    ) -> [UUID: NSRange] {
        let attributed = attributed ?? attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return [:] }

        var ranges: [UUID: NSRange] = [:]
        attributed.enumerateAttribute(
            Self.pendingAttachmentUploadPlaceholderAttribute,
            in: fullRange
        ) { value, range, _ in
            guard let value = value as? String,
                  let id = UUID(uuidString: value),
                  ranges[id] == nil else {
                return
            }
            ranges[id] = range
        }
        return ranges
    }

    @MainActor
    func reservePendingPasteSequence() -> UInt64 {
        let sequence = nextPendingPasteReservationSequence
        nextPendingPasteReservationSequence &+= 1
        return sequence
    }

    @MainActor
    func advanceLaterMarkerlessPasteReservations(
        after sequence: UInt64,
        anchoredAt anchor: Int,
        insertedLength: Int
    ) {
        guard insertedLength > 0 else { return }
        var updates: [UUID: TextBoxPendingPasteReservation] = [:]
        for (id, var reservation) in pendingPasteReservations
        where !reservation.usesMarker
            && reservation.sequence > sequence
            && reservation.replacementRange.location == anchor {
            reservation.replacementRange.location += insertedLength
            updates[id] = reservation
        }
        for (id, reservation) in updates {
            pendingPasteReservations[id] = reservation
        }
    }

    static func pasteReservationRangesIntersect(
        _ lhs: NSRange,
        _ rhs: NSRange
    ) -> Bool {
        if lhs.length == 0 {
            return rhs.length == 0
                ? false
                : lhs.location >= rhs.location
                    && lhs.location < NSMaxRange(rhs)
        }
        if rhs.length == 0 {
            return rhs.location >= lhs.location
                && rhs.location < NSMaxRange(lhs)
        }
        return NSIntersectionRange(lhs, rhs).length > 0
    }
}
