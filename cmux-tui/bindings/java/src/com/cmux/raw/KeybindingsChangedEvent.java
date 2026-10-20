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
    private final KeybindingsChangedEventOrigin origin;
    private final UInt64 revision;

    private KeybindingsChangedEvent(Builder builder) {
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public KeybindingsChangedEventOrigin origin() { return origin; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "keybindings-changed"; }

    public static KeybindingsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "KeybindingsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "keybindings-changed", "KeybindingsChangedEvent.event");
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
        Wire.put(object, "origin", origin);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof KeybindingsChangedEvent that)) return false;
        return Objects.equals(origin, that.origin) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(origin, revision); }

    @Override
    public String toString() { return "KeybindingsChangedEvent" + toWire(); }

    public static final class Builder {
        private KeybindingsChangedEventOrigin origin;
        private boolean originSet;
        private UInt64 revision;
        private boolean revisionSet;

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
