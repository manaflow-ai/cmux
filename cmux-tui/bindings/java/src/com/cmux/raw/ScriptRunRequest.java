// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable script-run request. Protocol v12; authority: local-admin. */
public final class ScriptRunRequest implements WireValue {
    private final Field<Object> args;
    private final String code;
    private final Field<UInt64> timeoutMs;

    private ScriptRunRequest(Builder builder) {
        this.args = builder.args.map(value -> Wire.immutableJson(value));
        if (!builder.codeSet) throw new IllegalArgumentException("code is required");
        this.code = Wire.nonNull(builder.code, "code");
        this.timeoutMs = builder.timeoutMs;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> args() { return args; }
    public String code() { return code; }
    public Field<UInt64> timeoutMs() { return timeoutMs; }

    public static ScriptRunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptRunRequest");
        Builder builder = builder();
        Object rawArgs = Wire.optional(object, "args");
        if (!Wire.isMissing(rawArgs)) {
            builder.args(rawArgs == null ? null : Wire.immutableJson(rawArgs));
        }
        Object rawCode = Wire.required(object, "code");
        builder.code(Wire.string(rawCode, "ScriptRunRequest.code"));
        Object rawTimeoutMs = Wire.optional(object, "timeout_ms");
        if (!Wire.isMissing(rawTimeoutMs)) {
            builder.timeoutMs(rawTimeoutMs == null ? null : Wire.uint64(rawTimeoutMs, "ScriptRunRequest.timeout_ms"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "args", args);
        Wire.put(object, "code", code);
        Wire.put(object, "timeout_ms", timeoutMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptRunRequest that)) return false;
        return Objects.equals(args, that.args) && Objects.equals(code, that.code) && Objects.equals(timeoutMs, that.timeoutMs);
    }

    @Override
    public int hashCode() { return Objects.hash(args, code, timeoutMs); }

    @Override
    public String toString() { return "ScriptRunRequest" + toWire(); }

    public static final class Builder {
        private Field<Object> args = Field.omitted();
        private String code;
        private boolean codeSet;
        private Field<UInt64> timeoutMs = Field.omitted();

        public Builder args(Object value) {
            this.args = Field.ofNullable(value);
            return this;
        }
        public Builder code(String value) {
            this.code = value;
            this.codeSet = true;
            return this;
        }
        public Builder timeoutMs(UInt64 value) {
            this.timeoutMs = Field.ofNullable(value);
            return this;
        }
        public ScriptRunRequest build() { return new ScriptRunRequest(this); }
    }
}
