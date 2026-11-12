// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable appearance-changed event. Protocol v12; streams: subscribe. */
public final class AppearanceChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 revision;

    private AppearanceChangedEvent(Builder builder) {
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 revision() { return revision; }
    @Override public String event() { return "appearance-changed"; }

    public static AppearanceChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "appearance-changed", "AppearanceChangedEvent.event");
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "AppearanceChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "appearance-changed");
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceChangedEvent that)) return false;
        return Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(revision); }

    @Override
    public String toString() { return "AppearanceChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 revision;
        private boolean revisionSet;

        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public AppearanceChangedEvent build() { return new AppearanceChangedEvent(this); }
    }
}
