// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable settings-changed event. Protocol v12; streams: subscribe. */
public final class SettingsChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final List<String> keys;
    private final SettingsChangedEventOrigin origin;
    private final UInt64 revision;

    private SettingsChangedEvent(Builder builder) {
        if (!builder.keysSet) throw new IllegalArgumentException("keys is required");
        this.keys = List.copyOf(Wire.nonNull(builder.keys, "keys"));
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> keys() { return keys; }
    public SettingsChangedEventOrigin origin() { return origin; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "settings-changed"; }

    public static SettingsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SettingsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "settings-changed", "SettingsChangedEvent.event");
        Object rawKeys = Wire.required(object, "keys");
        builder.keys(Wire.array(rawKeys, "SettingsChangedEvent.keys", item -> Wire.string(item, "SettingsChangedEvent.keys item")));
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(SettingsChangedEventOrigin.fromWire(rawOrigin));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "SettingsChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "settings-changed");
        Wire.put(object, "keys", keys);
        Wire.put(object, "origin", origin);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SettingsChangedEvent that)) return false;
        return Objects.equals(keys, that.keys) && Objects.equals(origin, that.origin) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(keys, origin, revision); }

    @Override
    public String toString() { return "SettingsChangedEvent" + toWire(); }

    public static final class Builder {
        private List<String> keys;
        private boolean keysSet;
        private SettingsChangedEventOrigin origin;
        private boolean originSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder keys(List<String> value) {
            this.keys = value;
            this.keysSet = true;
            return this;
        }
        public Builder origin(SettingsChangedEventOrigin value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public SettingsChangedEvent build() { return new SettingsChangedEvent(this); }
    }
}
