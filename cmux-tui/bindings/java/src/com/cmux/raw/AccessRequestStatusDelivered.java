// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AccessRequestStatusDelivered implements WireValue, AccessRequestStatus {
    private final Field<String> path;
    private final Field<Boolean> taken;
    private final Field<String> value;

    private AccessRequestStatusDelivered(Builder builder) {
        this.path = builder.path;
        this.taken = builder.taken;
        this.value = builder.value;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> path() { return path; }
    public String state() { return "delivered"; }
    public Field<Boolean> taken() { return taken; }
    public Field<String> value() { return value; }

    public static AccessRequestStatusDelivered fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestStatusDelivered");
        Builder builder = builder();
        Object rawPath = Wire.optional(object, "path");
        if (!Wire.isMissing(rawPath)) {
            builder.path(Wire.string(rawPath, "AccessRequestStatusDelivered.path"));
        }
        Object rawState = Wire.required(object, "state");
        ProtocolSupport.literal(rawState, "delivered", "AccessRequestStatusDelivered.state");
        Object rawTaken = Wire.optional(object, "taken");
        if (!Wire.isMissing(rawTaken)) {
            builder.taken(ProtocolSupport.literal(rawTaken, true, "AccessRequestStatusDelivered.taken"));
        }
        Object rawValue = Wire.optional(object, "value");
        if (!Wire.isMissing(rawValue)) {
            builder.value(Wire.string(rawValue, "AccessRequestStatusDelivered.value"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "path", path);
        Wire.put(object, "state", "delivered");
        Wire.put(object, "taken", taken);
        Wire.put(object, "value", value);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestStatusDelivered that)) return false;
        return Objects.equals(path, that.path) && Objects.equals(taken, that.taken) && Objects.equals(value, that.value);
    }

    @Override
    public int hashCode() { return Objects.hash(path, taken, value); }

    @Override
    public String toString() { return "AccessRequestStatusDelivered" + toWire(); }

    public static final class Builder {
        private Field<String> path = Field.omitted();
        private Field<Boolean> taken = Field.omitted();
        private Field<String> value = Field.omitted();

        public Builder path(String value) {
            this.path = Field.of(value);
            return this;
        }
        public Builder taken(Boolean value) {
            ProtocolSupport.literal(value, true, "AccessRequestStatusDelivered.taken");
            this.taken = Field.of(value);
            return this;
        }
        public Builder value(String value) {
            this.value = Field.of(value);
            return this;
        }
        public AccessRequestStatusDelivered build() { return new AccessRequestStatusDelivered(this); }
    }
}
