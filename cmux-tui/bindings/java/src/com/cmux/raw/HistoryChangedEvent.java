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
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final List<String> kinds;
    private final UInt64 revision;

    private HistoryChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.kindsSet) throw new IllegalArgumentException("kinds is required");
        this.kinds = List.copyOf(Wire.nonNull(builder.kinds, "kinds"));
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public List<String> kinds() { return kinds; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "history-changed"; }

    public static HistoryChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistoryChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "history-changed", "HistoryChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
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
        Wire.put(object, "cause", cause);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistoryChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(kinds, that.kinds) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, kinds, revision); }

    @Override
    public String toString() { return "HistoryChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private List<String> kinds;
        private boolean kindsSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
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
