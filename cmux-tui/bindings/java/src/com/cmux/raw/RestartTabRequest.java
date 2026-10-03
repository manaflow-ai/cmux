// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable restart-tab request. Protocol v12; authority: control. */
public final class RestartTabRequest implements WireValue {
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final Field<String> idempotencyKey;
    private final Field<Boolean> onlyLost;
    private final Object surface;
    private final Field<String> transaction;

    private RestartTabRequest(Builder builder) {
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.idempotencyKey = builder.idempotencyKey;
        this.onlyLost = builder.onlyLost;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public Field<Boolean> onlyLost() { return onlyLost; }
    public Object surface() { return surface; }
    public Field<String> transaction() { return transaction; }

    public static RestartTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RestartTabRequest");
        Builder builder = builder();
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "RestartTabRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "RestartTabRequest.env", item -> Wire.string(item, "RestartTabRequest.env value")));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "RestartTabRequest.idempotency_key"));
        }
        Object rawOnlyLost = Wire.optional(object, "only_lost");
        if (!Wire.isMissing(rawOnlyLost)) {
            builder.onlyLost(Wire.bool(rawOnlyLost, "RestartTabRequest.only_lost"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.immutableJson(rawSurface));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "RestartTabRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "only_lost", onlyLost);
        Wire.put(object, "surface", surface);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RestartTabRequest that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(onlyLost, that.onlyLost) && Objects.equals(surface, that.surface) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, env, idempotencyKey, onlyLost, surface, transaction); }

    @Override
    public String toString() { return "RestartTabRequest" + toWire(); }

    public static final class Builder {
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private Field<Boolean> onlyLost = Field.omitted();
        private Object surface;
        private boolean surfaceSet;
        private Field<String> transaction = Field.omitted();

        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder env(Map<String, String> value) {
            this.env = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = Field.ofNullable(value);
            return this;
        }
        public Builder onlyLost(Boolean value) {
            this.onlyLost = Field.of(value);
            return this;
        }
        public Builder surface(Object value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public RestartTabRequest build() { return new RestartTabRequest(this); }
    }
}
