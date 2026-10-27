// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable keybindings-changed event. Protocol v12; streams: subscribe. */
public final class KeybindingsChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final KeybindingsChangedEventOrigin origin;
    private final UInt64 revision;

    private KeybindingsChangedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public KeybindingsChangedEventOrigin origin() { return origin; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "keybindings-changed"; }

    public static KeybindingsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "KeybindingsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "keybindings-changed", "KeybindingsChangedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(KeybindingsChangedEventOrigin.fromWire(rawOrigin));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "KeybindingsChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "keybindings-changed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "origin", origin);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof KeybindingsChangedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(origin, that.origin) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, origin, revision); }

    @Override
    public String toString() { return "KeybindingsChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private KeybindingsChangedEventOrigin origin;
        private boolean originSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder origin(KeybindingsChangedEventOrigin value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public KeybindingsChangedEvent build() { return new KeybindingsChangedEvent(this); }
    }
}
