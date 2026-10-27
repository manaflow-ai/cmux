// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-abort request. Protocol v12; authority: local-admin. */
public final class AgentTransferAbortRequest implements WireValue {
    private final UInt64 surface;
    private final String transferId;

    private AgentTransferAbortRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.transferIdSet) throw new IllegalArgumentException("transfer_id is required");
        this.transferId = Wire.nonNull(builder.transferId, "transfer_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public String transferId() { return transferId; }

    public static AgentTransferAbortRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferAbortRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentTransferAbortRequest.surface"));
        Object rawTransferId = Wire.required(object, "transfer_id");
        builder.transferId(Wire.string(rawTransferId, "AgentTransferAbortRequest.transfer_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "transfer_id", transferId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferAbortRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(transferId, that.transferId);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, transferId); }

    @Override
    public String toString() { return "AgentTransferAbortRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private String transferId;
        private boolean transferIdSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder transferId(String value) {
            this.transferId = value;
            this.transferIdSet = true;
            return this;
        }
        public AgentTransferAbortRequest build() { return new AgentTransferAbortRequest(this); }
    }
}
