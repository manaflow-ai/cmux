// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferBeginResult implements WireValue {
    private final Object manifest;
    private final String sourceSession;
    private final String transferId;

    private AgentTransferBeginResult(Builder builder) {
        if (!builder.manifestSet) throw new IllegalArgumentException("manifest is required");
        this.manifest = Wire.immutableJson(Wire.nonNull(builder.manifest, "manifest"));
        if (!builder.sourceSessionSet) throw new IllegalArgumentException("source_session is required");
        this.sourceSession = Wire.nonNull(builder.sourceSession, "source_session");
        if (!builder.transferIdSet) throw new IllegalArgumentException("transfer_id is required");
        this.transferId = Wire.nonNull(builder.transferId, "transfer_id");
    }

    public static Builder builder() { return new Builder(); }

    public Object manifest() { return manifest; }
    public String sourceSession() { return sourceSession; }
    public String transferId() { return transferId; }

    public static AgentTransferBeginResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferBeginResult");
        Builder builder = builder();
        Object rawManifest = Wire.required(object, "manifest");
        builder.manifest(Wire.immutableJson(rawManifest));
        Object rawSourceSession = Wire.required(object, "source_session");
        builder.sourceSession(Wire.string(rawSourceSession, "AgentTransferBeginResult.source_session"));
        Object rawTransferId = Wire.required(object, "transfer_id");
        builder.transferId(Wire.string(rawTransferId, "AgentTransferBeginResult.transfer_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "manifest", manifest);
        Wire.put(object, "source_session", sourceSession);
        Wire.put(object, "transfer_id", transferId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferBeginResult that)) return false;
        return Objects.equals(manifest, that.manifest) && Objects.equals(sourceSession, that.sourceSession) && Objects.equals(transferId, that.transferId);
    }

    @Override
    public int hashCode() { return Objects.hash(manifest, sourceSession, transferId); }

    @Override
    public String toString() { return "AgentTransferBeginResult" + toWire(); }

    public static final class Builder {
        private Object manifest;
        private boolean manifestSet;
        private String sourceSession;
        private boolean sourceSessionSet;
        private String transferId;
        private boolean transferIdSet;

        public Builder manifest(Object value) {
            this.manifest = value;
            this.manifestSet = true;
            return this;
        }
        public Builder sourceSession(String value) {
            this.sourceSession = value;
            this.sourceSessionSet = true;
            return this;
        }
        public Builder transferId(String value) {
            this.transferId = value;
            this.transferIdSet = true;
            return this;
        }
        public AgentTransferBeginResult build() { return new AgentTransferBeginResult(this); }
    }
}
