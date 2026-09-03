// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable machine-stats request. Protocol v12; authority: control. */
public final class MachineStatsRequest implements WireValue {
    private final Field<Boolean> follow;

    private MachineStatsRequest(Builder builder) {
        this.follow = builder.follow;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> follow() { return follow; }

    public static MachineStatsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineStatsRequest");
        Builder builder = builder();
        Object rawFollow = Wire.optional(object, "follow");
        if (!Wire.isMissing(rawFollow)) {
            builder.follow(Wire.bool(rawFollow, "MachineStatsRequest.follow"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "follow", follow);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineStatsRequest that)) return false;
        return Objects.equals(follow, that.follow);
    }

    @Override
    public int hashCode() { return Objects.hash(follow); }

    @Override
    public String toString() { return "MachineStatsRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> follow = Field.omitted();

        public Builder follow(Boolean value) {
            this.follow = Field.of(value);
            return this;
        }
        public MachineStatsRequest build() { return new MachineStatsRequest(this); }
    }
}
