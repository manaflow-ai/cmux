// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserHostProviderResult implements WireValue {
    private final long hostPid;
    private final String secret;
    private final String socket;

    private BrowserHostProviderResult(Builder builder) {
        if (!builder.hostPidSet) throw new IllegalArgumentException("host_pid is required");
        this.hostPid = builder.hostPid;
        if (!builder.secretSet) throw new IllegalArgumentException("secret is required");
        this.secret = Wire.nonNull(builder.secret, "secret");
        if (!builder.socketSet) throw new IllegalArgumentException("socket is required");
        this.socket = Wire.nonNull(builder.socket, "socket");
    }

    public static Builder builder() { return new Builder(); }

    public long hostPid() { return hostPid; }
    public String secret() { return secret; }
    public String socket() { return socket; }

    public static BrowserHostProviderResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserHostProviderResult");
        Builder builder = builder();
        Object rawHostPid = Wire.required(object, "host_pid");
        builder.hostPid(Wire.uint32(rawHostPid, "BrowserHostProviderResult.host_pid"));
        Object rawSecret = Wire.required(object, "secret");
        builder.secret(Wire.string(rawSecret, "BrowserHostProviderResult.secret"));
        Object rawSocket = Wire.required(object, "socket");
        builder.socket(Wire.string(rawSocket, "BrowserHostProviderResult.socket"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "host_pid", hostPid);
        Wire.put(object, "secret", secret);
        Wire.put(object, "socket", socket);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserHostProviderResult that)) return false;
        return Objects.equals(hostPid, that.hostPid) && Objects.equals(secret, that.secret) && Objects.equals(socket, that.socket);
    }

    @Override
    public int hashCode() { return Objects.hash(hostPid, secret, socket); }

    @Override
    public String toString() { return "BrowserHostProviderResult" + toWire(); }

    public static final class Builder {
        private Long hostPid;
        private boolean hostPidSet;
        private String secret;
        private boolean secretSet;
        private String socket;
        private boolean socketSet;

        public Builder hostPid(long value) {
            this.hostPid = value;
            this.hostPidSet = true;
            return this;
        }
        public Builder secret(String value) {
            this.secret = value;
            this.secretSet = true;
            return this;
        }
        public Builder socket(String value) {
            this.socket = value;
            this.socketSet = true;
            return this;
        }
        public BrowserHostProviderResult build() { return new BrowserHostProviderResult(this); }
    }
}
