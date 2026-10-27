// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientHelloFeaturePending implements WireValue {
    private final boolean app;
    private final boolean daemon;
    private final String name;

    private ClientHelloFeaturePending(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = builder.app;
        if (!builder.daemonSet) throw new IllegalArgumentException("daemon is required");
        this.daemon = builder.daemon;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
    }

    public static Builder builder() { return new Builder(); }

    public boolean app() { return app; }
    public boolean daemon() { return daemon; }
    public String name() { return name; }

    public static ClientHelloFeaturePending fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloFeaturePending");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.bool(rawApp, "ClientHelloFeaturePending.app"));
        Object rawDaemon = Wire.required(object, "daemon");
        builder.daemon(Wire.bool(rawDaemon, "ClientHelloFeaturePending.daemon"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ClientHelloFeaturePending.name"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "daemon", daemon);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloFeaturePending that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(daemon, that.daemon) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(app, daemon, name); }

    @Override
    public String toString() { return "ClientHelloFeaturePending" + toWire(); }

    public static final class Builder {
        private Boolean app;
        private boolean appSet;
        private Boolean daemon;
        private boolean daemonSet;
        private String name;
        private boolean nameSet;

        public Builder app(boolean value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder daemon(boolean value) {
            this.daemon = value;
            this.daemonSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public ClientHelloFeaturePending build() { return new ClientHelloFeaturePending(this); }
    }
}
