// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppTerminalLink implements WireValue {
    private final String app;
    private final String channel;
    private final String id;
    private final String socket;
    private final String target;

    private AppTerminalLink(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        if (!builder.channelSet) throw new IllegalArgumentException("channel is required");
        this.channel = Wire.nonNull(builder.channel, "channel");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.socketSet) throw new IllegalArgumentException("socket is required");
        this.socket = builder.socket;
        if (!builder.targetSet) throw new IllegalArgumentException("target is required");
        this.target = Wire.nonNull(builder.target, "target");
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public String channel() { return channel; }
    public String id() { return id; }
    public String socket() { return socket; }
    public String target() { return target; }

    public static AppTerminalLink fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppTerminalLink");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "AppTerminalLink.app"));
        Object rawChannel = Wire.required(object, "channel");
        builder.channel(Wire.string(rawChannel, "AppTerminalLink.channel"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "AppTerminalLink.id"));
        Object rawSocket = Wire.required(object, "socket");
        builder.socket(rawSocket == null ? null : Wire.string(rawSocket, "AppTerminalLink.socket"));
        Object rawTarget = Wire.required(object, "target");
        builder.target(Wire.string(rawTarget, "AppTerminalLink.target"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "channel", channel);
        Wire.put(object, "id", id);
        Wire.put(object, "socket", socket);
        Wire.put(object, "target", target);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppTerminalLink that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(channel, that.channel) && Objects.equals(id, that.id) && Objects.equals(socket, that.socket) && Objects.equals(target, that.target);
    }

    @Override
    public int hashCode() { return Objects.hash(app, channel, id, socket, target); }

    @Override
    public String toString() { return "AppTerminalLink" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private String channel;
        private boolean channelSet;
        private String id;
        private boolean idSet;
        private String socket;
        private boolean socketSet;
        private String target;
        private boolean targetSet;

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder channel(String value) {
            this.channel = value;
            this.channelSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder socket(String value) {
            this.socket = value;
            this.socketSet = true;
            return this;
        }
        public Builder target(String value) {
            this.target = value;
            this.targetSet = true;
            return this;
        }
        public AppTerminalLink build() { return new AppTerminalLink(this); }
    }
}
