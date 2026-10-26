// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable size-state event. Protocol v12; streams: subscribe, attach-byte, attach-render. */
public final class SizeStateEvent implements WireValue, ByteAttachEvent, DeltaStreamEvent, ProtocolEvent, RenderAttachEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final Field<String> selfParticipant;
    private final SizeState state;
    private final UInt64 surface;

    private SizeStateEvent(Builder builder) {
        this.cause = builder.cause;
        this.selfParticipant = builder.selfParticipant;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public Field<String> selfParticipant() { return selfParticipant; }
    public SizeState state() { return state; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "size-state"; }

    public static SizeStateEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SizeStateEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "size-state", "SizeStateEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawSelfParticipant = Wire.optional(object, "self_participant");
        if (!Wire.isMissing(rawSelfParticipant)) {
            builder.selfParticipant(Wire.string(rawSelfParticipant, "SizeStateEvent.self_participant"));
        }
        Object rawState = Wire.required(object, "state");
        builder.state(SizeState.fromWire(rawState));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SizeStateEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "size-state");
        Wire.put(object, "cause", cause);
        Wire.put(object, "self_participant", selfParticipant);
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SizeStateEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(selfParticipant, that.selfParticipant) && Objects.equals(state, that.state) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, selfParticipant, state, surface); }

    @Override
    public String toString() { return "SizeStateEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private Field<String> selfParticipant = Field.omitted();
        private SizeState state;
        private boolean stateSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder selfParticipant(String value) {
            this.selfParticipant = Field.of(value);
            return this;
        }
        public Builder state(SizeState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SizeStateEvent build() { return new SizeStateEvent(this); }
    }
}
