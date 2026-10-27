// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserRuntimeStartResult implements WireValue {
    private final String installed;
    private final int port;
    private final UInt64 runtime;
    private final String secret;

    private BrowserRuntimeStartResult(Builder builder) {
        if (!builder.installedSet) throw new IllegalArgumentException("installed is required");
        this.installed = Wire.nonNull(builder.installed, "installed");
        if (!builder.portSet) throw new IllegalArgumentException("port is required");
        this.port = builder.port;
        if (!builder.runtimeSet) throw new IllegalArgumentException("runtime is required");
        this.runtime = Wire.nonNull(builder.runtime, "runtime");
        if (!builder.secretSet) throw new IllegalArgumentException("secret is required");
        this.secret = Wire.nonNull(builder.secret, "secret");
    }

    public static Builder builder() { return new Builder(); }

    public String installed() { return installed; }
    public int port() { return port; }
    public UInt64 runtime() { return runtime; }
    public String secret() { return secret; }

    public static BrowserRuntimeStartResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeStartResult");
        Builder builder = builder();
        Object rawInstalled = Wire.required(object, "installed");
        builder.installed(Wire.string(rawInstalled, "BrowserRuntimeStartResult.installed"));
        Object rawPort = Wire.required(object, "port");
        builder.port(Wire.uint16(rawPort, "BrowserRuntimeStartResult.port"));
        Object rawRuntime = Wire.required(object, "runtime");
        builder.runtime(Wire.uint64(rawRuntime, "BrowserRuntimeStartResult.runtime"));
        Object rawSecret = Wire.required(object, "secret");
        builder.secret(Wire.string(rawSecret, "BrowserRuntimeStartResult.secret"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "installed", installed);
        Wire.put(object, "port", port);
        Wire.put(object, "runtime", runtime);
        Wire.put(object, "secret", secret);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeStartResult that)) return false;
        return Objects.equals(installed, that.installed) && Objects.equals(port, that.port) && Objects.equals(runtime, that.runtime) && Objects.equals(secret, that.secret);
    }

    @Override
    public int hashCode() { return Objects.hash(installed, port, runtime, secret); }

    @Override
    public String toString() { return "BrowserRuntimeStartResult" + toWire(); }

    public static final class Builder {
        private String installed;
        private boolean installedSet;
        private Integer port;
        private boolean portSet;
        private UInt64 runtime;
        private boolean runtimeSet;
        private String secret;
        private boolean secretSet;

        public Builder installed(String value) {
            this.installed = value;
            this.installedSet = true;
            return this;
        }
        public Builder port(int value) {
            this.port = value;
            this.portSet = true;
            return this;
        }
        public Builder runtime(UInt64 value) {
            this.runtime = value;
            this.runtimeSet = true;
            return this;
        }
        public Builder secret(String value) {
            this.secret = value;
            this.secretSet = true;
            return this;
        }
        public BrowserRuntimeStartResult build() { return new BrowserRuntimeStartResult(this); }
    }
}
