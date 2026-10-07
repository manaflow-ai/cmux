package com.cmux;

import java.util.List;
import java.util.Objects;
import java.util.Optional;

/** One immutable record from the durable session journal. */
public record SessionJournalRecord(
    Decimal sequence,
    String eventId,
    int schemaVersion,
    String kind,
    JournalClass journalClass,
    ReplayPolicy replay,
    Decimal occurredAtMs,
    Decimal committedAtMs,
    Producer producer,
    Optional<Authority> authority,
    Optional<String> causationId,
    Optional<String> correlationId,
    int causationDepth,
    List<Subject> subjects,
    Sensitivity sensitivity,
    JsonValue payload,
    Optional<Decimal> resourceRevision,
    Optional<Decimal> previousResourceRevision
) {
    public enum JournalClass { STATE, OBSERVATION, EFFECT, CHECKPOINT }
    public enum ReplayPolicy { REQUIRED, ADVISORY, NEVER }
    public enum Sensitivity { PUBLIC, METADATA, SENSITIVE, SECRET }

    public record Producer(String kind, String id) {
        public Producer {
            Objects.requireNonNull(kind, "kind");
            Objects.requireNonNull(id, "id");
        }
    }

    public record Authority(
        String principalId,
        String leaseId,
        String generation,
        String role
    ) {
        public Authority {
            Objects.requireNonNull(principalId, "principalId");
            Objects.requireNonNull(leaseId, "leaseId");
            Objects.requireNonNull(generation, "generation");
            Objects.requireNonNull(role, "role");
        }
    }

    public record Subject(String kind, String id) {
        public Subject {
            Objects.requireNonNull(kind, "kind");
            Objects.requireNonNull(id, "id");
        }
    }

    public SessionJournalRecord {
        Objects.requireNonNull(sequence, "sequence");
        Objects.requireNonNull(eventId, "eventId");
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(journalClass, "journalClass");
        Objects.requireNonNull(replay, "replay");
        Objects.requireNonNull(occurredAtMs, "occurredAtMs");
        Objects.requireNonNull(committedAtMs, "committedAtMs");
        Objects.requireNonNull(producer, "producer");
        authority = authority == null ? Optional.empty() : authority;
        causationId = causationId == null ? Optional.empty() : causationId;
        correlationId = correlationId == null ? Optional.empty() : correlationId;
        subjects = List.copyOf(subjects);
        Objects.requireNonNull(sensitivity, "sensitivity");
        Objects.requireNonNull(payload, "payload");
        resourceRevision = resourceRevision == null ? Optional.empty() : resourceRevision;
        previousResourceRevision = previousResourceRevision == null
            ? Optional.empty()
            : previousResourceRevision;
    }
}
