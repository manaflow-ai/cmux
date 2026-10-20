package com.cmux;

import java.util.Objects;

/** One event schema declared by a userland journal producer. */
public record JournalEventSchema(
    String kind,
    long schemaVersion,
    SessionJournalRecord.JournalClass journalClass,
    SessionJournalRecord.ReplayPolicy replay,
    SessionJournalRecord.Sensitivity sensitivity,
    JsonValue payloadSchema
) {
    public JournalEventSchema {
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(journalClass, "journalClass");
        Objects.requireNonNull(replay, "replay");
        Objects.requireNonNull(sensitivity, "sensitivity");
        Objects.requireNonNull(payloadSchema, "payloadSchema");
    }
}
