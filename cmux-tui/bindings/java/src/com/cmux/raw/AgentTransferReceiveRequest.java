// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-receive request. Protocol v12; authority: local-admin. */
public final class AgentTransferReceiveRequest implements WireValue {
    private final String cwd;
    private final Map<String, Object> manifest;

    private AgentTransferReceiveRequest(Builder builder) {
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = Wire.nonNull(builder.cwd, "cwd");
        if (!builder.manifestSet) throw new IllegalArgumentException("manifest is required");
        this.manifest = Collections.unmodifiableMap(new LinkedHashMap<>(Wire.nonNull(builder.manifest, "manifest")));
    }

    public static Builder builder() { return new Builder(); }

    public String cwd() { return cwd; }
    public Map<String, Object> manifest() { return manifest; }

    public static AgentTransferReceiveRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReceiveRequest");
        Builder builder = builder();
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(Wire.string(rawCwd, "AgentTransferReceiveRequest.cwd"));
        Object rawManifest = Wire.required(object, "manifest");
        builder.manifest(Wire.map(rawManifest, "AgentTransferReceiveRequest.manifest", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "manifest", manifest);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReceiveRequest that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(manifest, that.manifest);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, manifest); }

    @Override
    public String toString() { return "AgentTransferReceiveRequest" + toWire(); }

    public static final class Builder {
        private String cwd;
        private boolean cwdSet;
        private Map<String, Object> manifest;
        private boolean manifestSet;

        public Builder cwd(String value) {
            this.cwd = value;
            this.cwdSet = true;
            return this;
        }
        public Builder manifest(Map<String, Object> value) {
            this.manifest = value;
            this.manifestSet = true;
            return this;
        }
        public AgentTransferReceiveRequest build() { return new AgentTransferReceiveRequest(this); }
    }
}
