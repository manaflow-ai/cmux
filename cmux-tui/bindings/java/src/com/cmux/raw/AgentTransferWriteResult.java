// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferWriteResult implements WireValue {
    private final UInt64 next;

    private AgentTransferWriteResult(Builder builder) {
        if (!builder.nextSet) throw new IllegalArgumentException("next is required");
        this.next = Wire.nonNull(builder.next, "next");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 next() { return next; }

    public static AgentTransferWriteResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferWriteResult");
        Builder builder = builder();
        Object rawNext = Wire.required(object, "next");
        builder.next(Wire.uint64(rawNext, "AgentTransferWriteResult.next"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "next", next);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferWriteResult that)) return false;
        return Objects.equals(next, that.next);
    }

    @Override
    public int hashCode() { return Objects.hash(next); }

    @Override
    public String toString() { return "AgentTransferWriteResult" + toWire(); }

    public static final class Builder {
        private UInt64 next;
        private boolean nextSet;

        public Builder next(UInt64 value) {
            this.next = value;
            this.nextSet = true;
            return this;
        }
        public AgentTransferWriteResult build() { return new AgentTransferWriteResult(this); }
    }
}
