// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GuestUrlClaimResult implements WireValue {
    private final boolean claimed;

    private GuestUrlClaimResult(Builder builder) {
        if (!builder.claimedSet) throw new IllegalArgumentException("claimed is required");
        this.claimed = builder.claimed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean claimed() { return claimed; }

    public static GuestUrlClaimResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GuestUrlClaimResult");
        Builder builder = builder();
        Object rawClaimed = Wire.required(object, "claimed");
        builder.claimed(Wire.bool(rawClaimed, "GuestUrlClaimResult.claimed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "claimed", claimed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GuestUrlClaimResult that)) return false;
        return Objects.equals(claimed, that.claimed);
    }

    @Override
    public int hashCode() { return Objects.hash(claimed); }

    @Override
    public String toString() { return "GuestUrlClaimResult" + toWire(); }

    public static final class Builder {
        private Boolean claimed;
        private boolean claimedSet;

        public Builder claimed(boolean value) {
            this.claimed = value;
            this.claimedSet = true;
            return this;
        }
        public GuestUrlClaimResult build() { return new GuestUrlClaimResult(this); }
    }
}
