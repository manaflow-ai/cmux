// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationAttachmentUploadResultStoredPreview implements WireValue {
    private final UInt64 byteCount;
    private final String hash;
    private final String mimeType;

    private ConversationAttachmentUploadResultStoredPreview(Builder builder) {
        if (!builder.byteCountSet) throw new IllegalArgumentException("byte_count is required");
        this.byteCount = Wire.nonNull(builder.byteCount, "byte_count");
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        if (!builder.mimeTypeSet) throw new IllegalArgumentException("mime_type is required");
        this.mimeType = Wire.nonNull(builder.mimeType, "mime_type");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 byteCount() { return byteCount; }
    public String hash() { return hash; }
    public String mimeType() { return mimeType; }

    public static ConversationAttachmentUploadResultStoredPreview fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentUploadResultStoredPreview");
        Builder builder = builder();
        Object rawByteCount = Wire.required(object, "byte_count");
        builder.byteCount(Wire.uint64(rawByteCount, "ConversationAttachmentUploadResultStoredPreview.byte_count"));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ConversationAttachmentUploadResultStoredPreview.hash"));
        Object rawMimeType = Wire.required(object, "mime_type");
        builder.mimeType(Wire.string(rawMimeType, "ConversationAttachmentUploadResultStoredPreview.mime_type"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "byte_count", byteCount);
        Wire.put(object, "hash", hash);
        Wire.put(object, "mime_type", mimeType);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentUploadResultStoredPreview that)) return false;
        return Objects.equals(byteCount, that.byteCount) && Objects.equals(hash, that.hash) && Objects.equals(mimeType, that.mimeType);
    }

    @Override
    public int hashCode() { return Objects.hash(byteCount, hash, mimeType); }

    @Override
    public String toString() { return "ConversationAttachmentUploadResultStoredPreview" + toWire(); }

    public static final class Builder {
        private UInt64 byteCount;
        private boolean byteCountSet;
        private String hash;
        private boolean hashSet;
        private String mimeType;
        private boolean mimeTypeSet;

        public Builder byteCount(UInt64 value) {
            this.byteCount = value;
            this.byteCountSet = true;
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
        public ConversationAttachmentUploadResultStoredPreview build() { return new ConversationAttachmentUploadResultStoredPreview(this); }
    }
}
