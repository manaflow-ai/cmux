// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable subscribe request. Protocol v5; authority: frontend. */
public final class SubscribeRequest implements WireValue {
    private final Field<UInt64> surface;
    private final Field<SubscribeRequestTreeEvents> treeEvents;

    private SubscribeRequest(Builder builder) {
        this.surface = builder.surface;
        this.treeEvents = builder.treeEvents;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> surface() { return surface; }
    public Field<SubscribeRequestTreeEvents> treeEvents() { return treeEvents; }

    public static SubscribeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SubscribeRequest");
        Builder builder = builder();
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SubscribeRequest.surface"));
        }
        Object rawTreeEvents = Wire.optional(object, "tree_events");
        if (!Wire.isMissing(rawTreeEvents)) {
            builder.treeEvents(rawTreeEvents == null ? null : SubscribeRequestTreeEvents.fromWire(rawTreeEvents));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "tree_events", treeEvents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SubscribeRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(treeEvents, that.treeEvents);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, treeEvents); }

    @Override
    public String toString() { return "SubscribeRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> surface = Field.omitted();
        private Field<SubscribeRequestTreeEvents> treeEvents = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder treeEvents(SubscribeRequestTreeEvents value) {
            this.treeEvents = Field.ofNullable(value);
            return this;
        }
        public SubscribeRequest build() { return new SubscribeRequest(this); }
    }
}
