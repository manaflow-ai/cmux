// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable usage-set-enabled request. Protocol v12; authority: local-admin. */
public final class UsageSetEnabledRequest implements WireValue {
    private final boolean on;

    private UsageSetEnabledRequest(Builder builder) {
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
    }

    public static Builder builder() { return new Builder(); }

    public boolean on() { return on; }

    public static UsageSetEnabledRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UsageSetEnabledRequest");
        Builder builder = builder();
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "UsageSetEnabledRequest.on"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "on", on);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UsageSetEnabledRequest that)) return false;
        return Objects.equals(on, that.on);
    }

    @Override
    public int hashCode() { return Objects.hash(on); }

    @Override
    public String toString() { return "UsageSetEnabledRequest" + toWire(); }

    public static final class Builder {
        private Boolean on;
        private boolean onSet;

        public Builder on(boolean value) {
            this.on = value;
            this.onSet = true;
            return this;
        }
        public UsageSetEnabledRequest build() { return new UsageSetEnabledRequest(this); }
    }
}
