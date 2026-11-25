// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable remote-host-call request. Protocol v12; authority: local-admin. */
public final class RemoteHostCallRequest implements WireValue {
    private final String method;
    private final Field<Object> params;

    private RemoteHostCallRequest(Builder builder) {
        if (!builder.methodSet) throw new IllegalArgumentException("method is required");
        this.method = Wire.nonNull(builder.method, "method");
        this.params = builder.params.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public String method() { return method; }
    public Field<Object> params() { return params; }

    public static RemoteHostCallRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoteHostCallRequest");
        Builder builder = builder();
        Object rawMethod = Wire.required(object, "method");
        builder.method(Wire.string(rawMethod, "RemoteHostCallRequest.method"));
        Object rawParams = Wire.optional(object, "params");
        if (!Wire.isMissing(rawParams)) {
            builder.params(rawParams == null ? null : Wire.immutableJson(rawParams));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "method", method);
        Wire.put(object, "params", params);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RemoteHostCallRequest that)) return false;
        return Objects.equals(method, that.method) && Objects.equals(params, that.params);
    }

    @Override
    public int hashCode() { return Objects.hash(method, params); }

    @Override
    public String toString() { return "RemoteHostCallRequest" + toWire(); }

    public static final class Builder {
        private String method;
        private boolean methodSet;
        private Field<Object> params = Field.omitted();

        public Builder method(String value) {
            this.method = value;
            this.methodSet = true;
            return this;
        }
        public Builder params(Object value) {
            this.params = Field.ofNullable(value);
            return this;
        }
        public RemoteHostCallRequest build() { return new RemoteHostCallRequest(this); }
    }
}
