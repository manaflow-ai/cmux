// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable read-scrollback request. Protocol v7; authority: control. */
public final class ReadScrollbackRequest implements WireValue {
    private final long count;
    private final long start;
    private final UInt64 surface;

    private ReadScrollbackRequest(Builder builder) {
        if (!builder.countSet) throw new IllegalArgumentException("count is required");
        this.count = builder.count;
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = builder.start;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public long count() { return count; }
    public long start() { return start; }
    public UInt64 surface() { return surface; }

    public static ReadScrollbackRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReadScrollbackRequest");
        Builder builder = builder();
        Object rawCount = Wire.required(object, "count");
        builder.count(Wire.uint32(rawCount, "ReadScrollbackRequest.count"));
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint32(rawStart, "ReadScrollbackRequest.start"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReadScrollbackRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "count", count);
        Wire.put(object, "start", start);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReadScrollbackRequest that)) return false;
        return Objects.equals(count, that.count) && Objects.equals(start, that.start) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(count, start, surface); }

    @Override
    public String toString() { return "ReadScrollbackRequest" + toWire(); }

    public static final class Builder {
        private Long count;
        private boolean countSet;
        private Long start;
        private boolean startSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder count(long value) {
            this.count = value;
            this.countSet = true;
            return this;
        }
        public Builder start(long value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ReadScrollbackRequest build() { return new ReadScrollbackRequest(this); }
    }
}
