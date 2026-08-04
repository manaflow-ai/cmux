// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SidebarPluginResult implements WireValue {
    private final String error;
    private final UInt64 retryAfterMs;
    private final UInt64 surface;

    private SidebarPluginResult(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = builder.error;
        if (!builder.retryAfterMsSet) throw new IllegalArgumentException("retry_after_ms is required");
        this.retryAfterMs = builder.retryAfterMs;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public UInt64 retryAfterMs() { return retryAfterMs; }
    public UInt64 surface() { return surface; }

    public static SidebarPluginResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SidebarPluginResult");
        Builder builder = builder();
        Object rawError = Wire.required(object, "error");
        builder.error(rawError == null ? null : Wire.string(rawError, "SidebarPluginResult.error"));
        Object rawRetryAfterMs = Wire.required(object, "retry_after_ms");
        builder.retryAfterMs(rawRetryAfterMs == null ? null : Wire.uint64(rawRetryAfterMs, "SidebarPluginResult.retry_after_ms"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SidebarPluginResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "error", error);
        Wire.put(object, "retry_after_ms", retryAfterMs);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SidebarPluginResult that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(retryAfterMs, that.retryAfterMs) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(error, retryAfterMs, surface); }

    @Override
    public String toString() { return "SidebarPluginResult" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private UInt64 retryAfterMs;
        private boolean retryAfterMsSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder retryAfterMs(UInt64 value) {
            this.retryAfterMs = value;
            this.retryAfterMsSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SidebarPluginResult build() { return new SidebarPluginResult(this); }
    }
}
