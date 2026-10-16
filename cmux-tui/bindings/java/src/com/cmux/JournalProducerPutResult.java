package com.cmux;

import java.util.Objects;

/** Receipt returned after a producer manifest is installed. */
public record JournalProducerPutResult(
    String producerId,
    long manifestVersion,
    String namespace,
    Decimal sequence,
    String eventId
) {
    public JournalProducerPutResult {
        Objects.requireNonNull(producerId, "producerId");
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(sequence, "sequence");
        Objects.requireNonNull(eventId, "eventId");
    }
}
