// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable stash-changed event. Protocol v12; streams: subscribe. */
public final class StashChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 revision;

    private StashChangedEvent(Builder builder) {
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 revision() { return revision; }
    @Override public String event() { return "stash-changed"; }

    public static StashChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "StashChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "stash-changed", "StashChangedEvent.event");
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "StashChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "stash-changed");
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof StashChangedEvent that)) return false;
        return Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(revision); }

    @Override
    public String toString() { return "StashChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 revision;
        private boolean revisionSet;

        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public StashChangedEvent build() { return new StashChangedEvent(this); }
    }
}
