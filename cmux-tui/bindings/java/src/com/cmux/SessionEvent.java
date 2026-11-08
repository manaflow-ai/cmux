package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Open typed union for protocol-v2 session event items. */
public sealed interface SessionEvent permits
        SessionEvent.Snapshot, SessionEvent.Delta, SessionEvent.Unknown {
    String kind();

    record Snapshot(
        Cursor cursor,
        Optional<String> resetReason,
        ResourceSnapshot snapshot
    ) implements SessionEvent {
        public Snapshot {
            Objects.requireNonNull(cursor, "cursor");
            resetReason = resetReason == null ? Optional.empty() : resetReason;
            resetReason.ifPresent(value -> {
                if (!List.of(
                        "initial",
                        "generation_changed",
                        "cursor_expired"
                    ).contains(value)) {
                    throw new IllegalArgumentException(
                        "resetReason has an unsupported value"
                    );
                }
            });
            Objects.requireNonNull(snapshot, "snapshot");
        }

        @Override
        public String kind() {
            return "snapshot";
        }
    }

    record Delta(
        Cursor cursor,
        Decimal previousRevision,
        Decimal revision,
        List<ResourceChange> changes
    ) implements SessionEvent {
        public Delta {
            Objects.requireNonNull(cursor, "cursor");
            Objects.requireNonNull(previousRevision, "previousRevision");
            Objects.requireNonNull(revision, "revision");
            changes = List.copyOf(changes);
            if (!revision.equals(cursor.revision())) {
                throw new IllegalArgumentException(
                    "delta revision must match its cursor"
                );
            }
        }

        @Override
        public String kind() {
            return "delta";
        }
    }

    record Unknown(
        String kind,
        Map<String, Object> raw
    ) implements SessionEvent {
        public Unknown {
            Objects.requireNonNull(kind, "kind");
            if (kind.isEmpty() || kind.equals("snapshot") || kind.equals("delta")) {
                throw new IllegalArgumentException(
                    "unknown session event requires an unrecognized non-empty kind"
                );
            }
            raw = JsonValue.immutableObject(raw, "unknown session event");
        }
    }
}
