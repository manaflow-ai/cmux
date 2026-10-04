// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SendResult implements WireValue {
    private final Field<String> delivery;

    private SendResult(Builder builder) {
        this.delivery = builder.delivery;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> delivery() { return delivery; }

    public static SendResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendResult");
        Builder builder = builder();
        Object rawDelivery = Wire.optional(object, "delivery");
        if (!Wire.isMissing(rawDelivery)) {
            builder.delivery(ProtocolSupport.literal(rawDelivery, "queued", "SendResult.delivery"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "delivery", delivery);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendResult that)) return false;
        return Objects.equals(delivery, that.delivery);
    }

    @Override
    public int hashCode() { return Objects.hash(delivery); }

    @Override
    public String toString() { return "SendResult" + toWire(); }

    public static final class Builder {
        private Field<String> delivery = Field.omitted();

        public Builder delivery(String value) {
            ProtocolSupport.literal(value, "queued", "SendResult.delivery");
            this.delivery = Field.of(value);
            return this;
        }
        public SendResult build() { return new SendResult(this); }
    }
}
