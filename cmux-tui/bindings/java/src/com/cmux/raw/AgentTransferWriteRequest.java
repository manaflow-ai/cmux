// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-write request. Protocol v12; authority: local-admin. */
public final class AgentTransferWriteRequest implements WireValue {
    private final Bytes data;
    private final UInt64 offset;
    private final String path;
    private final String receiveId;

    private AgentTransferWriteRequest(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        if (!builder.receiveIdSet) throw new IllegalArgumentException("receive_id is required");
        this.receiveId = Wire.nonNull(builder.receiveId, "receive_id");
    }

    public static Builder builder() { return new Builder(); }

    public Bytes data() { return data; }
    public UInt64 offset() { return offset; }
    public String path() { return path; }
    public String receiveId() { return receiveId; }

    public static AgentTransferWriteRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferWriteRequest");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "AgentTransferWriteRequest.data"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "AgentTransferWriteRequest.offset"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "AgentTransferWriteRequest.path"));
        Object rawReceiveId = Wire.required(object, "receive_id");
        builder.receiveId(Wire.string(rawReceiveId, "AgentTransferWriteRequest.receive_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "offset", offset);
        Wire.put(object, "path", path);
        Wire.put(object, "receive_id", receiveId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferWriteRequest that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(offset, that.offset) && Objects.equals(path, that.path) && Objects.equals(receiveId, that.receiveId);
    }

    @Override
    public int hashCode() { return Objects.hash(data, offset, path, receiveId); }

    @Override
    public String toString() { return "AgentTransferWriteRequest" + toWire(); }

    public static final class Builder {
        private Bytes data;
        private boolean dataSet;
        private UInt64 offset;
        private boolean offsetSet;
        private String path;
        private boolean pathSet;
        private String receiveId;
        private boolean receiveIdSet;

        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
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
        public Builder receiveId(String value) {
            this.receiveId = value;
            this.receiveIdSet = true;
            return this;
        }
        public AgentTransferWriteRequest build() { return new AgentTransferWriteRequest(this); }
    }
}
