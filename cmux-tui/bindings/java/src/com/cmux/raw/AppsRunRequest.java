// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-run request. Protocol v12; authority: local-admin. */
public final class AppsRunRequest implements WireValue {
    private final String app;
    private final Field<Object> args;
    private final Field<String> gesture;
    private final Field<String> idempotencyKey;
    private final String op;
    private final Field<AppOrigin> origin;

    private AppsRunRequest(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.args = builder.args.map(value -> Wire.immutableJson(value));
        this.gesture = builder.gesture;
        this.idempotencyKey = builder.idempotencyKey;
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<Object> args() { return args; }
    public Field<String> gesture() { return gesture; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public String op() { return op; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsRunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsRunRequest");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "AppsRunRequest.app"));
        Object rawArgs = Wire.optional(object, "args");
        if (!Wire.isMissing(rawArgs)) {
            builder.args(rawArgs == null ? null : Wire.immutableJson(rawArgs));
        }
        Object rawGesture = Wire.optional(object, "gesture");
        if (!Wire.isMissing(rawGesture)) {
            builder.gesture(rawGesture == null ? null : Wire.string(rawGesture, "AppsRunRequest.gesture"));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "AppsRunRequest.idempotency_key"));
        }
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "AppsRunRequest.op"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "args", args);
        Wire.put(object, "gesture", gesture);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "op", op);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsRunRequest that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(args, that.args) && Objects.equals(gesture, that.gesture) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(op, that.op) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(app, args, gesture, idempotencyKey, op, origin); }

    @Override
    public String toString() { return "AppsRunRequest" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<Object> args = Field.omitted();
        private Field<String> gesture = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private String op;
        private boolean opSet;
        private Field<AppOrigin> origin = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder args(Object value) {
            this.args = Field.ofNullable(value);
            return this;
        }
        public Builder gesture(String value) {
            this.gesture = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = Field.ofNullable(value);
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
        public AppsRunRequest build() { return new AppsRunRequest(this); }
    }
}
