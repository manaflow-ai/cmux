// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FlushLaunchSnapshotResult implements WireValue {
    private final boolean flushed;

    private FlushLaunchSnapshotResult(Builder builder) {
        if (!builder.flushedSet) throw new IllegalArgumentException("flushed is required");
        this.flushed = builder.flushed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean flushed() { return flushed; }

    public static FlushLaunchSnapshotResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FlushLaunchSnapshotResult");
        Builder builder = builder();
        Object rawFlushed = Wire.required(object, "flushed");
        builder.flushed(Wire.bool(rawFlushed, "FlushLaunchSnapshotResult.flushed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "flushed", flushed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FlushLaunchSnapshotResult that)) return false;
        return Objects.equals(flushed, that.flushed);
    }

    @Override
    public int hashCode() { return Objects.hash(flushed); }

    @Override
    public String toString() { return "FlushLaunchSnapshotResult" + toWire(); }

    public static final class Builder {
        private Boolean flushed;
        private boolean flushedSet;

        public Builder flushed(boolean value) {
            this.flushed = value;
            this.flushedSet = true;
            return this;
        }
        public FlushLaunchSnapshotResult build() { return new FlushLaunchSnapshotResult(this); }
    }
}
