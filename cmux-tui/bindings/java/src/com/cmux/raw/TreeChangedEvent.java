// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable tree-changed event. Protocol v5; streams: subscribe. */
public final class TreeChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {

    private TreeChangedEvent(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }

    @Override public String event() { return "tree-changed"; }

    public static TreeChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TreeChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "tree-changed", "TreeChangedEvent.event");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "tree-changed");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TreeChangedEvent that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "TreeChangedEvent" + toWire(); }

    public static final class Builder {

        public TreeChangedEvent build() { return new TreeChangedEvent(this); }
    }
}
