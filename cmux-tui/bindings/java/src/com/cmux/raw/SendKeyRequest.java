// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable send-key request. Protocol v6; authority: control. */
public final class SendKeyRequest implements WireValue {
    private final List<String> keys;
    private final UInt64 surface;

    private SendKeyRequest(Builder builder) {
        if (!builder.keysSet) throw new IllegalArgumentException("keys is required");
        this.keys = List.copyOf(Wire.nonNull(builder.keys, "keys"));
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> keys() { return keys; }
    public UInt64 surface() { return surface; }

    public static SendKeyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendKeyRequest");
        Builder builder = builder();
        Object rawKeys = Wire.required(object, "keys");
        builder.keys(Wire.array(rawKeys, "SendKeyRequest.keys", item -> Wire.string(item, "SendKeyRequest.keys item")));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SendKeyRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "keys", keys);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendKeyRequest that)) return false;
        return Objects.equals(keys, that.keys) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(keys, surface); }

    @Override
    public String toString() { return "SendKeyRequest" + toWire(); }

    public static final class Builder {
        private List<String> keys;
        private boolean keysSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder keys(List<String> value) {
            this.keys = value;
            this.keysSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SendKeyRequest build() { return new SendKeyRequest(this); }
    }
}
