// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsLockClasses implements WireValue {
    private final ServerStatsLockClassSet registry;
    private final ServerStatsLockClassSet registryConnection;
    private final ServerStatsLockClassSet state;

    private ServerStatsLockClasses(Builder builder) {
        if (!builder.registrySet) throw new IllegalArgumentException("registry is required");
        this.registry = Wire.nonNull(builder.registry, "registry");
        if (!builder.registryConnectionSet) throw new IllegalArgumentException("registry_connection is required");
        this.registryConnection = Wire.nonNull(builder.registryConnection, "registry_connection");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsLockClassSet registry() { return registry; }
    public ServerStatsLockClassSet registryConnection() { return registryConnection; }
    public ServerStatsLockClassSet state() { return state; }

    public static ServerStatsLockClasses fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsLockClasses");
        Builder builder = builder();
        Object rawRegistry = Wire.required(object, "registry");
        builder.registry(ServerStatsLockClassSet.fromWire(rawRegistry));
        Object rawRegistryConnection = Wire.required(object, "registry_connection");
        builder.registryConnection(ServerStatsLockClassSet.fromWire(rawRegistryConnection));
        Object rawState = Wire.required(object, "state");
        builder.state(ServerStatsLockClassSet.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "registry", registry);
        Wire.put(object, "registry_connection", registryConnection);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsLockClasses that)) return false;
        return Objects.equals(registry, that.registry) && Objects.equals(registryConnection, that.registryConnection) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(registry, registryConnection, state); }

    @Override
    public String toString() { return "ServerStatsLockClasses" + toWire(); }

    public static final class Builder {
        private ServerStatsLockClassSet registry;
        private boolean registrySet;
        private ServerStatsLockClassSet registryConnection;
        private boolean registryConnectionSet;
        private ServerStatsLockClassSet state;
        private boolean stateSet;

        public Builder registry(ServerStatsLockClassSet value) {
            this.registry = value;
            this.registrySet = true;
            return this;
        }
        public Builder registryConnection(ServerStatsLockClassSet value) {
            this.registryConnection = value;
            this.registryConnectionSet = true;
            return this;
        }
        public Builder state(ServerStatsLockClassSet value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public ServerStatsLockClasses build() { return new ServerStatsLockClasses(this); }
    }
}
