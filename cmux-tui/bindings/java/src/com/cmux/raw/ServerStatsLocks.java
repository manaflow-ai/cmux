// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLocks implements WireValue {
    private final ServerStatsLockDetail registry;
    private final ServerStatsLockDetail state;

    private ServerStatsLocks(Builder builder) {
        if (!builder.registrySet) throw new IllegalArgumentException("registry is required");
        this.registry = Wire.nonNull(builder.registry, "registry");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsLockDetail registry() { return registry; }
    public ServerStatsLockDetail state() { return state; }

    public static ServerStatsLocks fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLocks");
        Builder builder = builder();
        Object rawRegistry = Wire.required(object, "registry");
        builder.registry(ServerStatsLockDetail.fromWire(rawRegistry));
        Object rawState = Wire.required(object, "state");
        builder.state(ServerStatsLockDetail.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "registry", registry);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLocks that)) return false;
        return Objects.equals(registry, that.registry) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(registry, state); }

    @Override
    public String toString() { return "ServerStatsLocks" + toWire(); }

    public static final class Builder {
        private ServerStatsLockDetail registry;
        private boolean registrySet;
        private ServerStatsLockDetail state;
        private boolean stateSet;

        public Builder registry(ServerStatsLockDetail value) {
            this.registry = value;
            this.registrySet = true;
            return this;
        }
        public Builder state(ServerStatsLockDetail value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public ServerStatsLocks build() { return new ServerStatsLocks(this); }
    }
}
