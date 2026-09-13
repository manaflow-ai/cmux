// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable paste-image request. Protocol v12; authority: control. */
public final class PasteImageRequest implements WireValue {
    private final Field<String> data;
    private final String lease;
    private final Field<String> mime;
    private final Field<UInt64> offset;
    private final String op;
    private final Field<UInt64> size;
    private final UInt64 surface;
    private final String terminalId;
    private final String uploadId;

    private PasteImageRequest(Builder builder) {
        this.data = builder.data;
        if (!builder.leaseSet) throw new IllegalArgumentException("lease is required");
        this.lease = Wire.nonNull(builder.lease, "lease");
        this.mime = builder.mime;
        this.offset = builder.offset;
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        this.size = builder.size;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.uploadIdSet) throw new IllegalArgumentException("upload_id is required");
        this.uploadId = Wire.nonNull(builder.uploadId, "upload_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> data() { return data; }
    public String lease() { return lease; }
    public Field<String> mime() { return mime; }
    public Field<UInt64> offset() { return offset; }
    public String op() { return op; }
    public Field<UInt64> size() { return size; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String uploadId() { return uploadId; }

    public static PasteImageRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PasteImageRequest");
        Builder builder = builder();
        Object rawData = Wire.optional(object, "data");
        if (!Wire.isMissing(rawData)) {
            builder.data(rawData == null ? null : Wire.string(rawData, "PasteImageRequest.data"));
        }
        Object rawLease = Wire.required(object, "lease");
        builder.lease(Wire.string(rawLease, "PasteImageRequest.lease"));
        Object rawMime = Wire.optional(object, "mime");
        if (!Wire.isMissing(rawMime)) {
            builder.mime(rawMime == null ? null : Wire.string(rawMime, "PasteImageRequest.mime"));
        }
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(rawOffset == null ? null : Wire.uint64(rawOffset, "PasteImageRequest.offset"));
        }
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "PasteImageRequest.op"));
        Object rawSize = Wire.optional(object, "size");
        if (!Wire.isMissing(rawSize)) {
            builder.size(rawSize == null ? null : Wire.uint64(rawSize, "PasteImageRequest.size"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "PasteImageRequest.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "PasteImageRequest.terminal_id"));
        Object rawUploadId = Wire.required(object, "upload_id");
        builder.uploadId(Wire.string(rawUploadId, "PasteImageRequest.upload_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "lease", lease);
        Wire.put(object, "mime", mime);
        Wire.put(object, "offset", offset);
        Wire.put(object, "op", op);
        Wire.put(object, "size", size);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "upload_id", uploadId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PasteImageRequest that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(lease, that.lease) && Objects.equals(mime, that.mime) && Objects.equals(offset, that.offset) && Objects.equals(op, that.op) && Objects.equals(size, that.size) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(uploadId, that.uploadId);
    }

    @Override
    public int hashCode() { return Objects.hash(data, lease, mime, offset, op, size, surface, terminalId, uploadId); }

    @Override
    public String toString() { return "PasteImageRequest" + toWire(); }

    public static final class Builder {
        private Field<String> data = Field.omitted();
        private String lease;
        private boolean leaseSet;
        private Field<String> mime = Field.omitted();
        private Field<UInt64> offset = Field.omitted();
        private String op;
        private boolean opSet;
        private Field<UInt64> size = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String uploadId;
        private boolean uploadIdSet;

        public Builder data(String value) {
            this.data = Field.ofNullable(value);
            return this;
        }
        public Builder lease(String value) {
            this.lease = value;
            this.leaseSet = true;
            return this;
        }
        public Builder mime(String value) {
            this.mime = Field.ofNullable(value);
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.ofNullable(value);
            return this;
        }
        public Builder op(String value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public Builder size(UInt64 value) {
            this.size = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder uploadId(String value) {
            this.uploadId = value;
            this.uploadIdSet = true;
            return this;
        }
        public PasteImageRequest build() { return new PasteImageRequest(this); }
    }
}
