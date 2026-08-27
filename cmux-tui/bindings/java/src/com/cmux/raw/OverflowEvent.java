// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable overflow event. Protocol v7; streams: subscribe, attach-byte, attach-render, attach-browser. */
public final class OverflowEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, DeltaStreamEvent, ProtocolEvent, RenderAttachEvent, SubscribeEvent {
    private final String error;
    private final Field<String> scope;
    private final Field<UInt64> surface;

    private OverflowEvent(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = Wire.nonNull(builder.error, "error");
        this.scope = builder.scope;
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public Field<String> scope() { return scope; }
    public Field<UInt64> surface() { return surface; }
    @Override public String event() { return "overflow"; }

    public static OverflowEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "OverflowEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "overflow", "OverflowEvent.event");
        Object rawError = Wire.required(object, "error");
        builder.error(Wire.string(rawError, "OverflowEvent.error"));
        Object rawScope = Wire.optional(object, "scope");
        if (!Wire.isMissing(rawScope)) {
            builder.scope(ProtocolSupport.literal(rawScope, "surface", "OverflowEvent.scope"));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(Wire.uint64(rawSurface, "OverflowEvent.surface"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "overflow");
        Wire.put(object, "error", error);
        Wire.put(object, "scope", scope);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof OverflowEvent that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(scope, that.scope) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(error, scope, surface); }

    @Override
    public String toString() { return "OverflowEvent" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private Field<String> scope = Field.omitted();
        private Field<UInt64> surface = Field.omitted();

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder scope(String value) {
            ProtocolSupport.literal(value, "surface", "OverflowEvent.scope");
            this.scope = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.of(value);
            return this;
        }
        public OverflowEvent build() { return new OverflowEvent(this); }
    }
}
