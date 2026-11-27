// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable chief-work request. Protocol v12; authority: frontend. */
public final class ChiefWorkRequest implements WireValue {
    private final String chief;

    private ChiefWorkRequest(Builder builder) {
        if (!builder.chiefSet) throw new IllegalArgumentException("chief is required");
        this.chief = Wire.nonNull(builder.chief, "chief");
    }

    public static Builder builder() { return new Builder(); }

    public String chief() { return chief; }

    public static ChiefWorkRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefWorkRequest");
        Builder builder = builder();
        Object rawChief = Wire.required(object, "chief");
        builder.chief(Wire.string(rawChief, "ChiefWorkRequest.chief"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "chief", chief);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefWorkRequest that)) return false;
        return Objects.equals(chief, that.chief);
    }

    @Override
    public int hashCode() { return Objects.hash(chief); }

    @Override
    public String toString() { return "ChiefWorkRequest" + toWire(); }

    public static final class Builder {
        private String chief;
        private boolean chiefSet;

        public Builder chief(String value) {
            this.chief = value;
            this.chiefSet = true;
            return this;
        }
        public ChiefWorkRequest build() { return new ChiefWorkRequest(this); }
    }
}
