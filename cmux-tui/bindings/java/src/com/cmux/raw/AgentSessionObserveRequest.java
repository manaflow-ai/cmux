// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-observe request. Protocol v12; authority: local-admin. */
public final class AgentSessionObserveRequest implements WireValue {
    /** Records after this seq (oldest first). */
    private final Field<UInt64> afterSeq;
    /** Records before this seq (newest first). */
    private final Field<UInt64> beforeSeq;
    /** At most 32 acpmux record kinds or categories, each 1 to 64 bytes of [a-z_.]. */
    private final Field<List<String>> kinds;
    /** Records per page, clamped to 1..500 (default 200). */
    private final Field<UInt64> limit;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;

    private AgentSessionObserveRequest(Builder builder) {
        this.afterSeq = builder.afterSeq;
        this.beforeSeq = builder.beforeSeq;
        this.kinds = builder.kinds.map(value -> List.copyOf(value));
        this.limit = builder.limit;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterSeq() { return afterSeq; }
    public Field<UInt64> beforeSeq() { return beforeSeq; }
    public Field<List<String>> kinds() { return kinds; }
    public Field<UInt64> limit() { return limit; }
    public UInt64 surface() { return surface; }

    public static AgentSessionObserveRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionObserveRequest");
        Builder builder = builder();
        Object rawAfterSeq = Wire.optional(object, "after_seq");
        if (!Wire.isMissing(rawAfterSeq)) {
            builder.afterSeq(rawAfterSeq == null ? null : Wire.uint64(rawAfterSeq, "AgentSessionObserveRequest.after_seq"));
        }
        Object rawBeforeSeq = Wire.optional(object, "before_seq");
        if (!Wire.isMissing(rawBeforeSeq)) {
            builder.beforeSeq(rawBeforeSeq == null ? null : Wire.uint64(rawBeforeSeq, "AgentSessionObserveRequest.before_seq"));
        }
        Object rawKinds = Wire.optional(object, "kinds");
        if (!Wire.isMissing(rawKinds)) {
            builder.kinds(rawKinds == null ? null : Wire.array(rawKinds, "AgentSessionObserveRequest.kinds", item -> Wire.string(item, "AgentSessionObserveRequest.kinds item")));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint64(rawLimit, "AgentSessionObserveRequest.limit"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionObserveRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_seq", afterSeq);
        Wire.put(object, "before_seq", beforeSeq);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "limit", limit);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionObserveRequest that)) return false;
        return Objects.equals(afterSeq, that.afterSeq) && Objects.equals(beforeSeq, that.beforeSeq) && Objects.equals(kinds, that.kinds) && Objects.equals(limit, that.limit) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(afterSeq, beforeSeq, kinds, limit, surface); }

    @Override
    public String toString() { return "AgentSessionObserveRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterSeq = Field.omitted();
        private Field<UInt64> beforeSeq = Field.omitted();
        private Field<List<String>> kinds = Field.omitted();
        private Field<UInt64> limit = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder afterSeq(UInt64 value) {
            this.afterSeq = Field.ofNullable(value);
            return this;
        }
        public Builder beforeSeq(UInt64 value) {
            this.beforeSeq = Field.ofNullable(value);
            return this;
        }
        public Builder kinds(List<String> value) {
            this.kinds = Field.ofNullable(value);
            return this;
        }
        public Builder limit(UInt64 value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionObserveRequest build() { return new AgentSessionObserveRequest(this); }
    }
}
