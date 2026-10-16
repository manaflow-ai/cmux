package com.cmux;

import java.util.List;
import java.util.Objects;

/** Manifest installed by a userland journal producer. */
public record JournalProducerManifest(
    String producerId,
    String namespace,
    long manifestVersion,
    SessionJournalRecord.Sensitivity maxSensitivity,
    List<String> permissions,
    List<JournalEventSchema> events
) {
    public JournalProducerManifest {
        Objects.requireNonNull(producerId, "producerId");
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(maxSensitivity, "maxSensitivity");
        permissions = permissions == null ? List.of() : List.copyOf(permissions);
        events = events == null ? List.of() : List.copyOf(events);
    }

    public java.util.Map<String, Object> toWire() {
        return JournalWire.manifest(this);
    }
}
