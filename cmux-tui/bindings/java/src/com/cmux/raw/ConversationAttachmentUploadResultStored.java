// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationAttachmentUploadResultStored implements WireValue {
    private final UInt64 byteCount;
    private final String hash;
    private final String mimeType;
    private final Field<ConversationAttachmentUploadResultStoredPoster> poster;
    private final Field<ConversationAttachmentUploadResultStoredPreview> preview;

    private ConversationAttachmentUploadResultStored(Builder builder) {
        if (!builder.byteCountSet) throw new IllegalArgumentException("byte_count is required");
        this.byteCount = Wire.nonNull(builder.byteCount, "byte_count");
        if (!builder.hashSet) throw new IllegalArgumentException("hash is required");
        this.hash = Wire.nonNull(builder.hash, "hash");
        if (!builder.mimeTypeSet) throw new IllegalArgumentException("mime_type is required");
        this.mimeType = Wire.nonNull(builder.mimeType, "mime_type");
        this.poster = builder.poster;
        this.preview = builder.preview;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 byteCount() { return byteCount; }
    public String hash() { return hash; }
    public String mimeType() { return mimeType; }
    public Field<ConversationAttachmentUploadResultStoredPoster> poster() { return poster; }
    public Field<ConversationAttachmentUploadResultStoredPreview> preview() { return preview; }

    public static ConversationAttachmentUploadResultStored fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentUploadResultStored");
        Builder builder = builder();
        Object rawByteCount = Wire.required(object, "byte_count");
        builder.byteCount(Wire.uint64(rawByteCount, "ConversationAttachmentUploadResultStored.byte_count"));
        Object rawHash = Wire.required(object, "hash");
        builder.hash(Wire.string(rawHash, "ConversationAttachmentUploadResultStored.hash"));
        Object rawMimeType = Wire.required(object, "mime_type");
        builder.mimeType(Wire.string(rawMimeType, "ConversationAttachmentUploadResultStored.mime_type"));
        Object rawPoster = Wire.optional(object, "poster");
        if (!Wire.isMissing(rawPoster)) {
            builder.poster(rawPoster == null ? null : ConversationAttachmentUploadResultStoredPoster.fromWire(rawPoster));
        }
        Object rawPreview = Wire.optional(object, "preview");
        if (!Wire.isMissing(rawPreview)) {
            builder.preview(rawPreview == null ? null : ConversationAttachmentUploadResultStoredPreview.fromWire(rawPreview));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "byte_count", byteCount);
        Wire.put(object, "hash", hash);
        Wire.put(object, "mime_type", mimeType);
        Wire.put(object, "poster", poster);
        Wire.put(object, "preview", preview);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentUploadResultStored that)) return false;
        return Objects.equals(byteCount, that.byteCount) && Objects.equals(hash, that.hash) && Objects.equals(mimeType, that.mimeType) && Objects.equals(poster, that.poster) && Objects.equals(preview, that.preview);
    }

    @Override
    public int hashCode() { return Objects.hash(byteCount, hash, mimeType, poster, preview); }

    @Override
    public String toString() { return "ConversationAttachmentUploadResultStored" + toWire(); }

    public static final class Builder {
        private UInt64 byteCount;
        private boolean byteCountSet;
        private String hash;
        private boolean hashSet;
        private String mimeType;
        private boolean mimeTypeSet;
        private Field<ConversationAttachmentUploadResultStoredPoster> poster = Field.omitted();
        private Field<ConversationAttachmentUploadResultStoredPreview> preview = Field.omitted();

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
        public Builder poster(ConversationAttachmentUploadResultStoredPoster value) {
            this.poster = Field.ofNullable(value);
            return this;
        }
        public Builder preview(ConversationAttachmentUploadResultStoredPreview value) {
            this.preview = Field.ofNullable(value);
            return this;
        }
        public ConversationAttachmentUploadResultStored build() { return new ConversationAttachmentUploadResultStored(this); }
    }
}
