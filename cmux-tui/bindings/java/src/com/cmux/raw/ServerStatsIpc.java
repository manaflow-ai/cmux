// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpc implements WireValue {
    private final List<ServerStatsMethodLatency> methods;

    private ServerStatsIpc(Builder builder) {
        if (!builder.methodsSet) throw new IllegalArgumentException("methods is required");
        this.methods = List.copyOf(Wire.nonNull(builder.methods, "methods"));
    }

    public static Builder builder() { return new Builder(); }

    public List<ServerStatsMethodLatency> methods() { return methods; }

    public static ServerStatsIpc fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpc");
        Builder builder = builder();
        Object rawMethods = Wire.required(object, "methods");
        builder.methods(Wire.array(rawMethods, "ServerStatsIpc.methods", item -> ServerStatsMethodLatency.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "methods", methods);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpc that)) return false;
        return Objects.equals(methods, that.methods);
    }

    @Override
    public int hashCode() { return Objects.hash(methods); }

    @Override
    public String toString() { return "ServerStatsIpc" + toWire(); }

    public static final class Builder {
        private List<ServerStatsMethodLatency> methods;
        private boolean methodsSet;

        public Builder methods(List<ServerStatsMethodLatency> value) {
            this.methods = value;
            this.methodsSet = true;
            return this;
        }
        public ServerStatsIpc build() { return new ServerStatsIpc(this); }
    }
}
