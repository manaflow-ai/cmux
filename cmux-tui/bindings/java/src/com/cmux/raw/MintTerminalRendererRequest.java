// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable mint-terminal-renderer request. Protocol v9; authority: frontend. */
public final class MintTerminalRendererRequest implements WireValue {
    private final UInt64 surface;
    private final Field<UInt64> ttlMs;

    private MintTerminalRendererRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.ttlMs = builder.ttlMs;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public Field<UInt64> ttlMs() { return ttlMs; }

    public static MintTerminalRendererRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MintTerminalRendererRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MintTerminalRendererRequest.surface"));
        Object rawTtlMs = Wire.optional(object, "ttl_ms");
        if (!Wire.isMissing(rawTtlMs)) {
            builder.ttlMs(Wire.uint64(rawTtlMs, "MintTerminalRendererRequest.ttl_ms"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "ttl_ms", ttlMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MintTerminalRendererRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(ttlMs, that.ttlMs);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, ttlMs); }

    @Override
    public String toString() { return "MintTerminalRendererRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<UInt64> ttlMs = Field.omitted();

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder ttlMs(UInt64 value) {
            this.ttlMs = Field.of(value);
            return this;
        }
        public MintTerminalRendererRequest build() { return new MintTerminalRendererRequest(this); }
    }
}
