// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsCommandConnections implements WireValue {
    private final UInt64 accepted;
    private final String kind;
    private final UInt64 refused;

    private ServerStatsCommandConnections(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = Wire.nonNull(builder.accepted, "accepted");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.refusedSet) throw new IllegalArgumentException("refused is required");
        this.refused = Wire.nonNull(builder.refused, "refused");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 accepted() { return accepted; }
    public String kind() { return kind; }
    public UInt64 refused() { return refused; }

    public static ServerStatsCommandConnections fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsCommandConnections");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.uint64(rawAccepted, "ServerStatsCommandConnections.accepted"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsCommandConnections.kind"));
        Object rawRefused = Wire.required(object, "refused");
        builder.refused(Wire.uint64(rawRefused, "ServerStatsCommandConnections.refused"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        Wire.put(object, "kind", kind);
        Wire.put(object, "refused", refused);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsCommandConnections that)) return false;
        return Objects.equals(accepted, that.accepted) && Objects.equals(kind, that.kind) && Objects.equals(refused, that.refused);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted, kind, refused); }

    @Override
    public String toString() { return "ServerStatsCommandConnections" + toWire(); }

    public static final class Builder {
        private UInt64 accepted;
        private boolean acceptedSet;
        private String kind;
        private boolean kindSet;
        private UInt64 refused;
        private boolean refusedSet;

        public Builder accepted(UInt64 value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder refused(UInt64 value) {
            this.refused = value;
            this.refusedSet = true;
            return this;
        }
        public ServerStatsCommandConnections build() { return new ServerStatsCommandConnections(this); }
    }
}
