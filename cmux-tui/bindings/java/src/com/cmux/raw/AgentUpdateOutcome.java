// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentUpdateOutcome implements WireValue {
    private final Field<String> error;
    private final String id;
    private final boolean ok;
    private final Field<String> version;

    private AgentUpdateOutcome(Builder builder) {
        this.error = builder.error;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.okSet) throw new IllegalArgumentException("ok is required");
        this.ok = builder.ok;
        this.version = builder.version;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> error() { return error; }
    public String id() { return id; }
    public boolean ok() { return ok; }
    public Field<String> version() { return version; }

    public static AgentUpdateOutcome fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentUpdateOutcome");
        Builder builder = builder();
        Object rawError = Wire.optional(object, "error");
        if (!Wire.isMissing(rawError)) {
            builder.error(Wire.string(rawError, "AgentUpdateOutcome.error"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "AgentUpdateOutcome.id"));
        Object rawOk = Wire.required(object, "ok");
        builder.ok(Wire.bool(rawOk, "AgentUpdateOutcome.ok"));
        Object rawVersion = Wire.optional(object, "version");
        if (!Wire.isMissing(rawVersion)) {
            builder.version(Wire.string(rawVersion, "AgentUpdateOutcome.version"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "error", error);
        Wire.put(object, "id", id);
        Wire.put(object, "ok", ok);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentUpdateOutcome that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(id, that.id) && Objects.equals(ok, that.ok) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(error, id, ok, version); }

    @Override
    public String toString() { return "AgentUpdateOutcome" + toWire(); }

    public static final class Builder {
        private Field<String> error = Field.omitted();
        private String id;
        private boolean idSet;
        private Boolean ok;
        private boolean okSet;
        private Field<String> version = Field.omitted();

        public Builder error(String value) {
            this.error = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder ok(boolean value) {
            this.ok = value;
            this.okSet = true;
            return this;
        }
        public Builder version(String value) {
            this.version = Field.of(value);
            return this;
        }
        public AgentUpdateOutcome build() { return new AgentUpdateOutcome(this); }
    }
}
