// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SendExpectAgent implements WireValue {
    private final Field<String> session;

    private SendExpectAgent(Builder builder) {
        this.session = builder.session;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> session() { return session; }

    public static SendExpectAgent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendExpectAgent");
        Builder builder = builder();
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(rawSession == null ? null : Wire.string(rawSession, "SendExpectAgent.session"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendExpectAgent that)) return false;
        return Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(session); }

    @Override
    public String toString() { return "SendExpectAgent" + toWire(); }

    public static final class Builder {
        private Field<String> session = Field.omitted();

        public Builder session(String value) {
            this.session = Field.ofNullable(value);
            return this;
        }
        public SendExpectAgent build() { return new SendExpectAgent(this); }
    }
}
