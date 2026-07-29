package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Closed typed union for protocol-v1 session event items. */
public sealed interface SessionEvent permits
        SessionEvent.Snapshot, SessionEvent.Delta, SessionEvent.Unknown {
    String kind();

    record Snapshot(
        Cursor cursor,
        Optional<String> resetReason,
        Map<String, Object> snapshot
    ) implements SessionEvent {
        public Snapshot {
            Objects.requireNonNull(cursor, "cursor");
            resetReason = resetReason == null ? Optional.empty() : resetReason;
            snapshot = Map.copyOf(snapshot);
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
        List<Map<String, Object>> changes
    ) implements SessionEvent {
        public Delta {
            Objects.requireNonNull(cursor, "cursor");
            Objects.requireNonNull(previousRevision, "previousRevision");
            Objects.requireNonNull(revision, "revision");
            changes = List.copyOf(changes);
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
            raw = Map.copyOf(raw);
        }
    }
}
