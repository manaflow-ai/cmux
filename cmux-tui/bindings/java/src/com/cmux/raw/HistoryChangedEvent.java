// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable history-changed event. Protocol v12; streams: subscribe. */
public final class HistoryChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final List<String> kinds;
    private final UInt64 revision;

    private HistoryChangedEvent(Builder builder) {
        if (!builder.kindsSet) throw new IllegalArgumentException("kinds is required");
        this.kinds = List.copyOf(Wire.nonNull(builder.kinds, "kinds"));
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> kinds() { return kinds; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "history-changed"; }

    public static HistoryChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistoryChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "history-changed", "HistoryChangedEvent.event");
        Object rawKinds = Wire.required(object, "kinds");
        builder.kinds(Wire.array(rawKinds, "HistoryChangedEvent.kinds", item -> Wire.string(item, "HistoryChangedEvent.kinds item")));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "HistoryChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "history-changed");
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistoryChangedEvent that)) return false;
        return Objects.equals(kinds, that.kinds) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(kinds, revision); }

    @Override
    public String toString() { return "HistoryChangedEvent" + toWire(); }

    public static final class Builder {
        private List<String> kinds;
        private boolean kindsSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder kinds(List<String> value) {
            this.kinds = value;
            this.kindsSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public HistoryChangedEvent build() { return new HistoryChangedEvent(this); }
    }
}
