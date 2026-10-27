// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-store request. Protocol v12; authority: local-admin. */
public final class AppsStoreRequest implements WireValue {
    private final Field<Object> args;
    private final String op;
    private final Field<AppOrigin> origin;

    private AppsStoreRequest(Builder builder) {
        this.args = builder.args.map(value -> Wire.immutableJson(value));
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> args() { return args; }
    public String op() { return op; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsStoreRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsStoreRequest");
        Builder builder = builder();
        Object rawArgs = Wire.optional(object, "args");
        if (!Wire.isMissing(rawArgs)) {
            builder.args(rawArgs == null ? null : Wire.immutableJson(rawArgs));
        }
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "AppsStoreRequest.op"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "args", args);
        Wire.put(object, "op", op);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsStoreRequest that)) return false;
        return Objects.equals(args, that.args) && Objects.equals(op, that.op) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(args, op, origin); }

    @Override
    public String toString() { return "AppsStoreRequest" + toWire(); }

    public static final class Builder {
        private Field<Object> args = Field.omitted();
        private String op;
        private boolean opSet;
        private Field<AppOrigin> origin = Field.omitted();

        public Builder args(Object value) {
            this.args = Field.ofNullable(value);
            return this;
        }
        public Builder op(String value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsStoreRequest build() { return new AppsStoreRequest(this); }
    }
}
