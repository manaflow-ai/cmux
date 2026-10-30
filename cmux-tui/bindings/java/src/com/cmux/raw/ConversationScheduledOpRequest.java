// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-scheduled-op request. Protocol v12; authority: local-admin. */
public final class ConversationScheduledOpRequest implements WireValue {
    private final Object op;

    private ConversationScheduledOpRequest(Builder builder) {
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = builder.op == null ? null : Wire.immutableJson(builder.op);
    }

    public static Builder builder() { return new Builder(); }

    public Object op() { return op; }

    public static ConversationScheduledOpRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationScheduledOpRequest");
        Builder builder = builder();
        Object rawOp = Wire.required(object, "op");
        builder.op(rawOp == null ? null : Wire.immutableJson(rawOp));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "op", op);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationScheduledOpRequest that)) return false;
        return Objects.equals(op, that.op);
    }

    @Override
    public int hashCode() { return Objects.hash(op); }

    @Override
    public String toString() { return "ConversationScheduledOpRequest" + toWire(); }

    public static final class Builder {
        private Object op;
        private boolean opSet;

        public Builder op(Object value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public ConversationScheduledOpRequest build() { return new ConversationScheduledOpRequest(this); }
    }
}
