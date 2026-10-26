// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-read request. Protocol v12; authority: local-admin. */
public final class AgentTransferReadRequest implements WireValue {
    private final Field<UInt64> limit;
    private final UInt64 offset;
    private final String path;
    private final String transferId;

    private AgentTransferReadRequest(Builder builder) {
        this.limit = builder.limit;
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        if (!builder.transferIdSet) throw new IllegalArgumentException("transfer_id is required");
        this.transferId = Wire.nonNull(builder.transferId, "transfer_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> limit() { return limit; }
    public UInt64 offset() { return offset; }
    public String path() { return path; }
    public String transferId() { return transferId; }

    public static AgentTransferReadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReadRequest");
        Builder builder = builder();
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint64(rawLimit, "AgentTransferReadRequest.limit"));
        }
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "AgentTransferReadRequest.offset"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "AgentTransferReadRequest.path"));
        Object rawTransferId = Wire.required(object, "transfer_id");
        builder.transferId(Wire.string(rawTransferId, "AgentTransferReadRequest.transfer_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "limit", limit);
        Wire.put(object, "offset", offset);
        Wire.put(object, "path", path);
        Wire.put(object, "transfer_id", transferId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReadRequest that)) return false;
        return Objects.equals(limit, that.limit) && Objects.equals(offset, that.offset) && Objects.equals(path, that.path) && Objects.equals(transferId, that.transferId);
    }

    @Override
    public int hashCode() { return Objects.hash(limit, offset, path, transferId); }

    @Override
    public String toString() { return "AgentTransferReadRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> limit = Field.omitted();
        private UInt64 offset;
        private boolean offsetSet;
        private String path;
        private boolean pathSet;
        private String transferId;
        private boolean transferIdSet;

        public Builder limit(UInt64 value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder transferId(String value) {
            this.transferId = value;
            this.transferIdSet = true;
            return this;
        }
        public AgentTransferReadRequest build() { return new AgentTransferReadRequest(this); }
    }
}
