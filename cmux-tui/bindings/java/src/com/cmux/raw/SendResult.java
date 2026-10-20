// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SendResult implements WireValue {
    private final Field<Boolean> queued;

    private SendResult(Builder builder) {
        this.queued = builder.queued;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> queued() { return queued; }

    public static SendResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendResult");
        Builder builder = builder();
        Object rawQueued = Wire.optional(object, "queued");
        if (!Wire.isMissing(rawQueued)) {
            builder.queued(Wire.bool(rawQueued, "SendResult.queued"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "queued", queued);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendResult that)) return false;
        return Objects.equals(queued, that.queued);
    }

    @Override
    public int hashCode() { return Objects.hash(queued); }

    @Override
    public String toString() { return "SendResult" + toWire(); }

    public static final class Builder {
        private Field<Boolean> queued = Field.omitted();

        public Builder queued(Boolean value) {
            this.queued = Field.of(value);
            return this;
        }
        public SendResult build() { return new SendResult(this); }
    }
}
