// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserProviderUnregisterResult implements WireValue {
    private final boolean removed;

    private BrowserProviderUnregisterResult(Builder builder) {
        if (!builder.removedSet) throw new IllegalArgumentException("removed is required");
        this.removed = builder.removed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean removed() { return removed; }

    public static BrowserProviderUnregisterResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserProviderUnregisterResult");
        Builder builder = builder();
        Object rawRemoved = Wire.required(object, "removed");
        builder.removed(Wire.bool(rawRemoved, "BrowserProviderUnregisterResult.removed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "removed", removed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserProviderUnregisterResult that)) return false;
        return Objects.equals(removed, that.removed);
    }

    @Override
    public int hashCode() { return Objects.hash(removed); }

    @Override
    public String toString() { return "BrowserProviderUnregisterResult" + toWire(); }

    public static final class Builder {
        private Boolean removed;
        private boolean removedSet;

        public Builder removed(boolean value) {
            this.removed = value;
            this.removedSet = true;
            return this;
        }
        public BrowserProviderUnregisterResult build() { return new BrowserProviderUnregisterResult(this); }
    }
}
