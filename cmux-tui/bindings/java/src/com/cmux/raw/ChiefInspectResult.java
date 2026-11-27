// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ChiefInspectResult implements WireValue {
    private final Field<Object> body;
    private final Field<String> error;
    private final UInt64 status;

    private ChiefInspectResult(Builder builder) {
        this.body = builder.body.map(value -> Wire.immutableJson(value));
        this.error = builder.error;
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> body() { return body; }
    public Field<String> error() { return error; }
    public UInt64 status() { return status; }

    public static ChiefInspectResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefInspectResult");
        Builder builder = builder();
        Object rawBody = Wire.optional(object, "body");
        if (!Wire.isMissing(rawBody)) {
            builder.body(rawBody == null ? null : Wire.immutableJson(rawBody));
        }
        Object rawError = Wire.optional(object, "error");
        if (!Wire.isMissing(rawError)) {
            builder.error(rawError == null ? null : Wire.string(rawError, "ChiefInspectResult.error"));
        }
        Object rawStatus = Wire.required(object, "status");
        builder.status(Wire.uint64(rawStatus, "ChiefInspectResult.status"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "body", body);
        Wire.put(object, "error", error);
        Wire.put(object, "status", status);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefInspectResult that)) return false;
        return Objects.equals(body, that.body) && Objects.equals(error, that.error) && Objects.equals(status, that.status);
    }

    @Override
    public int hashCode() { return Objects.hash(body, error, status); }

    @Override
    public String toString() { return "ChiefInspectResult" + toWire(); }

    public static final class Builder {
        private Field<Object> body = Field.omitted();
        private Field<String> error = Field.omitted();
        private UInt64 status;
        private boolean statusSet;

        public Builder body(Object value) {
            this.body = Field.ofNullable(value);
            return this;
        }
        public Builder error(String value) {
            this.error = Field.ofNullable(value);
            return this;
        }
        public Builder status(UInt64 value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public ChiefInspectResult build() { return new ChiefInspectResult(this); }
    }
}
