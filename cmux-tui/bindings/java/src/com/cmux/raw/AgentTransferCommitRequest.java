// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-commit request. Protocol v12; authority: local-admin. */
public final class AgentTransferCommitRequest implements WireValue {
    private final UInt64 surface;
    private final Object to_;
    private final String transferId;

    private AgentTransferCommitRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.to_Set) throw new IllegalArgumentException("to is required");
        this.to_ = builder.to_ == null ? null : Wire.immutableJson(builder.to_);
        if (!builder.transferIdSet) throw new IllegalArgumentException("transfer_id is required");
        this.transferId = Wire.nonNull(builder.transferId, "transfer_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public Object to_() { return to_; }
    public String transferId() { return transferId; }

    public static AgentTransferCommitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferCommitRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentTransferCommitRequest.surface"));
        Object rawTo = Wire.required(object, "to");
        builder.to_(rawTo == null ? null : Wire.immutableJson(rawTo));
        Object rawTransferId = Wire.required(object, "transfer_id");
        builder.transferId(Wire.string(rawTransferId, "AgentTransferCommitRequest.transfer_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "to", to_);
        Wire.put(object, "transfer_id", transferId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferCommitRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(to_, that.to_) && Objects.equals(transferId, that.transferId);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, to_, transferId); }

    @Override
    public String toString() { return "AgentTransferCommitRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private Object to_;
        private boolean to_Set;
        private String transferId;
        private boolean transferIdSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder to_(Object value) {
            this.to_ = value;
            this.to_Set = true;
            return this;
        }
        public Builder transferId(String value) {
            this.transferId = value;
            this.transferIdSet = true;
            return this;
        }
        public AgentTransferCommitRequest build() { return new AgentTransferCommitRequest(this); }
    }
}
