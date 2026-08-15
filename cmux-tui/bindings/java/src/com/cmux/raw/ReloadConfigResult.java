// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReloadConfigResult implements WireValue {
    private final String path;

    private ReloadConfigResult(Builder builder) {
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = builder.path;
    }

    public static Builder builder() { return new Builder(); }

    public String path() { return path; }
    public Boolean reloaded() { return true; }

    public static ReloadConfigResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReloadConfigResult");
        Builder builder = builder();
        Object rawPath = Wire.required(object, "path");
        builder.path(rawPath == null ? null : Wire.string(rawPath, "ReloadConfigResult.path"));
        Object rawReloaded = Wire.required(object, "reloaded");
        ProtocolSupport.literal(rawReloaded, true, "ReloadConfigResult.reloaded");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "path", path);
        Wire.put(object, "reloaded", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReloadConfigResult that)) return false;
        return Objects.equals(path, that.path);
    }

    @Override
    public int hashCode() { return Objects.hash(path); }

    @Override
    public String toString() { return "ReloadConfigResult" + toWire(); }

    public static final class Builder {
        private String path;
        private boolean pathSet;

        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public ReloadConfigResult build() { return new ReloadConfigResult(this); }
    }
}
