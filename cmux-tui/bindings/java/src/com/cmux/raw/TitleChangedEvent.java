// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable title-changed event. Protocol v5; streams: subscribe. */
public final class TitleChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 surface;
    private final Field<String> title;

    private TitleChangedEvent(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.title = builder.title;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public Field<String> title() { return title; }
    @Override public String event() { return "title-changed"; }

    public static TitleChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TitleChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "title-changed", "TitleChangedEvent.event");
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TitleChangedEvent.surface"));
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(Wire.string(rawTitle, "TitleChangedEvent.title"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "title-changed");
        Wire.put(object, "surface", surface);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TitleChangedEvent that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, title); }

    @Override
    public String toString() { return "TitleChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> title = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = Field.of(value);
            return this;
        }
        public TitleChangedEvent build() { return new TitleChangedEvent(this); }
    }
}
