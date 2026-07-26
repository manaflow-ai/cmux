import AppKit

extension TextBoxInputTextView {
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
}
