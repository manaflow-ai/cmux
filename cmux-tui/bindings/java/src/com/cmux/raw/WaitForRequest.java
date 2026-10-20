// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable wait-for request. Protocol v6; authority: control. */
public final class WaitForRequest implements WireValue {
    private final String pattern;
    private final UInt64 surface;
    /** Zero performs one immediate check. */
    private final UInt64 timeoutMs;

    private WaitForRequest(Builder builder) {
        if (!builder.patternSet) throw new IllegalArgumentException("pattern is required");
        this.pattern = Wire.nonNull(builder.pattern, "pattern");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.timeoutMsSet) throw new IllegalArgumentException("timeout_ms is required");
        this.timeoutMs = Wire.nonNull(builder.timeoutMs, "timeout_ms");
    }

    public static Builder builder() { return new Builder(); }

    public String pattern() { return pattern; }
    public UInt64 surface() { return surface; }
    public UInt64 timeoutMs() { return timeoutMs; }

    public static WaitForRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WaitForRequest");
        Builder builder = builder();
        Object rawPattern = Wire.required(object, "pattern");
        builder.pattern(Wire.string(rawPattern, "WaitForRequest.pattern"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "WaitForRequest.surface"));
        Object rawTimeoutMs = Wire.required(object, "timeout_ms");
        builder.timeoutMs(Wire.uint64(rawTimeoutMs, "WaitForRequest.timeout_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pattern", pattern);
        Wire.put(object, "surface", surface);
        Wire.put(object, "timeout_ms", timeoutMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WaitForRequest that)) return false;
        return Objects.equals(pattern, that.pattern) && Objects.equals(surface, that.surface) && Objects.equals(timeoutMs, that.timeoutMs);
    }

    @Override
    public int hashCode() { return Objects.hash(pattern, surface, timeoutMs); }

    @Override
    public String toString() { return "WaitForRequest" + toWire(); }

    public static final class Builder {
        private String pattern;
        private boolean patternSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private UInt64 timeoutMs;
        private boolean timeoutMsSet;

        public Builder pattern(String value) {
            this.pattern = value;
            this.patternSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder timeoutMs(UInt64 value) {
            this.timeoutMs = value;
            this.timeoutMsSet = true;
            return this;
        }
        public WaitForRequest build() { return new WaitForRequest(this); }
    }
}
