// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable computer-use-config request. Protocol v12; authority: local-admin. */
public final class ComputerUseConfigRequest implements WireValue {
    private final Object config;

    private ComputerUseConfigRequest(Builder builder) {
        if (!builder.configSet) throw new IllegalArgumentException("config is required");
        this.config = builder.config == null ? null : Wire.immutableJson(builder.config);
    }

    public static Builder builder() { return new Builder(); }

    public Object config() { return config; }

    public static ComputerUseConfigRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ComputerUseConfigRequest");
        Builder builder = builder();
        Object rawConfig = Wire.required(object, "config");
        builder.config(rawConfig == null ? null : Wire.immutableJson(rawConfig));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "config", config);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ComputerUseConfigRequest that)) return false;
        return Objects.equals(config, that.config);
    }

    @Override
    public int hashCode() { return Objects.hash(config); }

    @Override
    public String toString() { return "ComputerUseConfigRequest" + toWire(); }

    public static final class Builder {
        private Object config;
        private boolean configSet;

        public Builder config(Object value) {
            this.config = value;
            this.configSet = true;
            return this;
        }
        public ComputerUseConfigRequest build() { return new ComputerUseConfigRequest(this); }
    }
}
