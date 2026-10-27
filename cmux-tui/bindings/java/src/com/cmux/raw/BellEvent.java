// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable bell event. Protocol v5; streams: subscribe. */
public final class BellEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final UInt64 surface;

    private BellEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "bell"; }

    public static BellEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BellEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "bell", "BellEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BellEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "bell");
        Wire.put(object, "cause", cause);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BellEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, surface); }

    @Override
    public String toString() { return "BellEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public BellEvent build() { return new BellEvent(this); }
    }
}
