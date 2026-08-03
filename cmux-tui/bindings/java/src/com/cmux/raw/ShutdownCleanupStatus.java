// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ShutdownCleanupStatus implements WireValue {
    private final boolean degraded;
    private final UInt64 pending;
    private final boolean retrying;

    private ShutdownCleanupStatus(Builder builder) {
        if (!builder.degradedSet) throw new IllegalArgumentException("degraded is required");
        this.degraded = builder.degraded;
        if (!builder.pendingSet) throw new IllegalArgumentException("pending is required");
        this.pending = Wire.nonNull(builder.pending, "pending");
        if (!builder.retryingSet) throw new IllegalArgumentException("retrying is required");
        this.retrying = builder.retrying;
    }

    public static Builder builder() { return new Builder(); }

    public boolean degraded() { return degraded; }
    public UInt64 pending() { return pending; }
    public boolean retrying() { return retrying; }

    public static ShutdownCleanupStatus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShutdownCleanupStatus");
        Builder builder = builder();
        Object rawDegraded = Wire.required(object, "degraded");
        builder.degraded(Wire.bool(rawDegraded, "ShutdownCleanupStatus.degraded"));
        Object rawPending = Wire.required(object, "pending");
        builder.pending(Wire.uint64(rawPending, "ShutdownCleanupStatus.pending"));
        Object rawRetrying = Wire.required(object, "retrying");
        builder.retrying(Wire.bool(rawRetrying, "ShutdownCleanupStatus.retrying"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "degraded", degraded);
        Wire.put(object, "pending", pending);
        Wire.put(object, "retrying", retrying);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShutdownCleanupStatus that)) return false;
        return Objects.equals(degraded, that.degraded) && Objects.equals(pending, that.pending) && Objects.equals(retrying, that.retrying);
    }

    @Override
    public int hashCode() { return Objects.hash(degraded, pending, retrying); }

    @Override
    public String toString() { return "ShutdownCleanupStatus" + toWire(); }

    public static final class Builder {
        private Boolean degraded;
        private boolean degradedSet;
        private UInt64 pending;
        private boolean pendingSet;
        private Boolean retrying;
        private boolean retryingSet;

        public Builder degraded(boolean value) {
            this.degraded = value;
            this.degradedSet = true;
            return this;
        }
        public Builder pending(UInt64 value) {
            this.pending = value;
            this.pendingSet = true;
            return this;
        }
        public Builder retrying(boolean value) {
            this.retrying = value;
            this.retryingSet = true;
            return this;
        }
        public ShutdownCleanupStatus build() { return new ShutdownCleanupStatus(this); }
    }
}
