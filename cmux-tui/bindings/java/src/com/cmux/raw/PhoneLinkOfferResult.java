// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PhoneLinkOfferResult implements WireValue {
    private final boolean offered;

    private PhoneLinkOfferResult(Builder builder) {
        if (!builder.offeredSet) throw new IllegalArgumentException("offered is required");
        this.offered = builder.offered;
    }

    public static Builder builder() { return new Builder(); }

    public boolean offered() { return offered; }

    public static PhoneLinkOfferResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PhoneLinkOfferResult");
        Builder builder = builder();
        Object rawOffered = Wire.required(object, "offered");
        builder.offered(Wire.bool(rawOffered, "PhoneLinkOfferResult.offered"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "offered", offered);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PhoneLinkOfferResult that)) return false;
        return Objects.equals(offered, that.offered);
    }

    @Override
    public int hashCode() { return Objects.hash(offered); }

    @Override
    public String toString() { return "PhoneLinkOfferResult" + toWire(); }

    public static final class Builder {
        private Boolean offered;
        private boolean offeredSet;

        public Builder offered(boolean value) {
            this.offered = value;
            this.offeredSet = true;
            return this;
        }
        public PhoneLinkOfferResult build() { return new PhoneLinkOfferResult(this); }
    }
}
