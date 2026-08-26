// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable clear-history request. Protocol v9; authority: control. */
public final class ClearHistoryRequest implements WireValue {
    private final Field<TerminalKeyInput> fallbackKey;
    private final UInt64 surface;

    private ClearHistoryRequest(Builder builder) {
        this.fallbackKey = builder.fallbackKey;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalKeyInput> fallbackKey() { return fallbackKey; }
    public UInt64 surface() { return surface; }

    public static ClearHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClearHistoryRequest");
        Builder builder = builder();
        Object rawFallbackKey = Wire.optional(object, "fallback_key");
        if (!Wire.isMissing(rawFallbackKey)) {
            builder.fallbackKey(rawFallbackKey == null ? null : TerminalKeyInput.fromWire(rawFallbackKey));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ClearHistoryRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "fallback_key", fallbackKey);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClearHistoryRequest that)) return false;
        return Objects.equals(fallbackKey, that.fallbackKey) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(fallbackKey, surface); }

    @Override
    public String toString() { return "ClearHistoryRequest" + toWire(); }

    public static final class Builder {
        private Field<TerminalKeyInput> fallbackKey = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder fallbackKey(TerminalKeyInput value) {
            this.fallbackKey = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ClearHistoryRequest build() { return new ClearHistoryRequest(this); }
    }
}
