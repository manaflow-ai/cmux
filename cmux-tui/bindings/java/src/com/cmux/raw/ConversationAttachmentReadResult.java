// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationAttachmentReadResult implements WireValue {
    private final UInt64 byteCount;
    private final String data;
    private final boolean eof;
    private final String hash;
    private final String mimeType;
    private final UInt64 offset;

    private ConversationAttachmentReadResult(Builder builder) {
        if (!builder.byteCountSet) throw new IllegalArgumentException("byte_count is required");
        this.byteCount = Wire.nonNull(builder.byteCount, "byte_count");
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.eofSet) throw new IllegalArgumentException("eof is required");
        this.eof = builder.eof;
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        if (!builder.mimeTypeSet) throw new IllegalArgumentException("mime_type is required");
        this.mimeType = Wire.nonNull(builder.mimeType, "mime_type");
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 byteCount() { return byteCount; }
    public String data() { return data; }
    public boolean eof() { return eof; }
    public String hash() { return hash; }
    public String mimeType() { return mimeType; }
    public UInt64 offset() { return offset; }

    public static ConversationAttachmentReadResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentReadResult");
        Builder builder = builder();
        Object rawByteCount = Wire.required(object, "byte_count");
        builder.byteCount(Wire.uint64(rawByteCount, "ConversationAttachmentReadResult.byte_count"));
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "ConversationAttachmentReadResult.data"));
        Object rawEof = Wire.required(object, "eof");
        builder.eof(Wire.bool(rawEof, "ConversationAttachmentReadResult.eof"));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ConversationAttachmentReadResult.hash"));
        Object rawMimeType = Wire.required(object, "mime_type");
        builder.mimeType(Wire.string(rawMimeType, "ConversationAttachmentReadResult.mime_type"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "ConversationAttachmentReadResult.offset"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "byte_count", byteCount);
        Wire.put(object, "data", data);
        Wire.put(object, "eof", eof);
        Wire.put(object, "hash", hash);
        Wire.put(object, "mime_type", mimeType);
        Wire.put(object, "offset", offset);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentReadResult that)) return false;
        return Objects.equals(byteCount, that.byteCount) && Objects.equals(data, that.data) && Objects.equals(eof, that.eof) && Objects.equals(hash, that.hash) && Objects.equals(mimeType, that.mimeType) && Objects.equals(offset, that.offset);
    }

    @Override
    public int hashCode() { return Objects.hash(byteCount, data, eof, hash, mimeType, offset); }

    @Override
    public String toString() { return "ConversationAttachmentReadResult" + toWire(); }

    public static final class Builder {
        private UInt64 byteCount;
        private boolean byteCountSet;
        private String data;
        private boolean dataSet;
        private Boolean eof;
        private boolean eofSet;
        private String hash;
        private boolean hashSet;
        private String mimeType;
        private boolean mimeTypeSet;
        private UInt64 offset;
        private boolean offsetSet;

        public Builder byteCount(UInt64 value) {
            this.byteCount = value;
            this.byteCountSet = true;
            return this;
        }
        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder eof(boolean value) {
            this.eof = value;
            this.eofSet = true;
            return this;
        }
        public Builder hash(String value) {
            this.hash = value;
            this.hashSet = true;
            return this;
        }
        public Builder mimeType(String value) {
            this.mimeType = value;
            this.mimeTypeSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public ConversationAttachmentReadResult build() { return new ConversationAttachmentReadResult(this); }
    }
}
