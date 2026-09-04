// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable machine-usage request. Protocol v12; authority: control. */
public final class MachineUsageRequest implements WireValue {

    private MachineUsageRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static MachineUsageRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineUsageRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineUsageRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "MachineUsageRequest" + toWire(); }

    public static final class Builder {

        public MachineUsageRequest build() { return new MachineUsageRequest(this); }
    }
}
