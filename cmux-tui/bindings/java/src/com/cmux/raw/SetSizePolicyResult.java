// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetSizePolicyResult implements WireValue {
    private final Field<SizeState> state;

    private SetSizePolicyResult(Builder builder) {
        this.state = builder.state;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizeState> state() { return state; }

    public static SetSizePolicyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSizePolicyResult");
        Builder builder = builder();
        Object rawState = Wire.optional(object, "state");
        if (!Wire.isMissing(rawState)) {
            builder.state(SizeState.fromWire(rawState));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSizePolicyResult that)) return false;
        return Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(state); }

    @Override
    public String toString() { return "SetSizePolicyResult" + toWire(); }

    public static final class Builder {
        private Field<SizeState> state = Field.omitted();

        public Builder state(SizeState value) {
            this.state = Field.of(value);
            return this;
        }
        public SetSizePolicyResult build() { return new SetSizePolicyResult(this); }
    }
}
