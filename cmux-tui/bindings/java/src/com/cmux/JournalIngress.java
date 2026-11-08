package com.cmux;

import java.util.List;
import java.util.Objects;
import java.util.Optional;

/** Generic journal event envelope emitted by a userland producer. */
public record JournalIngress(
    String producerId,
    long manifestVersion,
    String kind,
    long schemaVersion,
    Optional<Decimal> occurredAtMs,
    List<SessionJournalRecord.Subject> subjects,
    Optional<SessionJournalRecord.Sensitivity> sensitivity,
    JsonValue payload,
    Optional<String> causationId,
    Optional<String> correlationId
) {
    public JournalIngress {
        Objects.requireNonNull(producerId, "producerId");
        Objects.requireNonNull(kind, "kind");
        occurredAtMs = occurredAtMs == null ? Optional.empty() : occurredAtMs;
        subjects = subjects == null ? List.of() : List.copyOf(subjects);
        sensitivity = sensitivity == null ? Optional.empty() : sensitivity;
        Objects.requireNonNull(payload, "payload");
        causationId = causationId == null ? Optional.empty() : causationId;
        correlationId = correlationId == null ? Optional.empty() : correlationId;
    }

    public java.util.Map<String, Object> toWire() {
        return JournalWire.ingress(this);
    }
}
