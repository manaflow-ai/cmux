// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-agents request. Protocol v6; authority: control. */
public final class ListAgentsRequest implements WireValue {
    private final Field<AgentState> state;
    private final Field<UInt64> surface;

    private ListAgentsRequest(Builder builder) {
        this.state = builder.state;
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AgentState> state() { return state; }
    public Field<UInt64> surface() { return surface; }

    public static ListAgentsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListAgentsRequest");
        Builder builder = builder();
        Object rawState = Wire.optional(object, "state");
        if (!Wire.isMissing(rawState)) {
            builder.state(rawState == null ? null : AgentState.fromWire(rawState));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "ListAgentsRequest.surface"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListAgentsRequest that)) return false;
        return Objects.equals(state, that.state) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(state, surface); }

    @Override
    public String toString() { return "ListAgentsRequest" + toWire(); }

    public static final class Builder {
        private Field<AgentState> state = Field.omitted();
        private Field<UInt64> surface = Field.omitted();

        public Builder state(AgentState value) {
            this.state = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public ListAgentsRequest build() { return new ListAgentsRequest(this); }
    }
}
