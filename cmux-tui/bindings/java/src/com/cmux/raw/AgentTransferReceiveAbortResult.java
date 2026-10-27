// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferReceiveAbortResult implements WireValue {
    private final boolean dropped;
    private final boolean forgotten;
    private final Boolean landed;

    private AgentTransferReceiveAbortResult(Builder builder) {
        if (!builder.droppedSet) throw new IllegalArgumentException("dropped is required");
        this.dropped = builder.dropped;
        if (!builder.forgottenSet) throw new IllegalArgumentException("forgotten is required");
        this.forgotten = builder.forgotten;
        if (!builder.landedSet) throw new IllegalArgumentException("landed is required");
        this.landed = builder.landed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean dropped() { return dropped; }
    public boolean forgotten() { return forgotten; }
    public Boolean landed() { return landed; }

    public static AgentTransferReceiveAbortResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReceiveAbortResult");
        Builder builder = builder();
        Object rawDropped = Wire.required(object, "dropped");
        builder.dropped(Wire.bool(rawDropped, "AgentTransferReceiveAbortResult.dropped"));
        Object rawForgotten = Wire.required(object, "forgotten");
        builder.forgotten(Wire.bool(rawForgotten, "AgentTransferReceiveAbortResult.forgotten"));
        Object rawLanded = Wire.required(object, "landed");
        builder.landed(rawLanded == null ? null : Wire.bool(rawLanded, "AgentTransferReceiveAbortResult.landed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dropped", dropped);
        Wire.put(object, "forgotten", forgotten);
        Wire.put(object, "landed", landed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReceiveAbortResult that)) return false;
        return Objects.equals(dropped, that.dropped) && Objects.equals(forgotten, that.forgotten) && Objects.equals(landed, that.landed);
    }

    @Override
    public int hashCode() { return Objects.hash(dropped, forgotten, landed); }

    @Override
    public String toString() { return "AgentTransferReceiveAbortResult" + toWire(); }

    public static final class Builder {
        private Boolean dropped;
        private boolean droppedSet;
        private Boolean forgotten;
        private boolean forgottenSet;
        private Boolean landed;
        private boolean landedSet;

        public Builder dropped(boolean value) {
            this.dropped = value;
            this.droppedSet = true;
            return this;
        }
        public Builder forgotten(boolean value) {
            this.forgotten = value;
            this.forgottenSet = true;
            return this;
        }
        public Builder landed(Boolean value) {
            this.landed = value;
            this.landedSet = true;
            return this;
        }
        public AgentTransferReceiveAbortResult build() { return new AgentTransferReceiveAbortResult(this); }
    }
}
