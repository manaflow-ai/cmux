package com.cmux;

import java.util.Objects;

/** Receipt returned after a journal event is appended. */
public record JournalAppendResult(
    String producerId,
    Decimal sequence,
    String eventId
) {
    public JournalAppendResult {
        Objects.requireNonNull(producerId, "producerId");
        Objects.requireNonNull(sequence, "sequence");
        Objects.requireNonNull(eventId, "eventId");
    }
}
