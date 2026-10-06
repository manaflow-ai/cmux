// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-attachment-upload request. Protocol v12; authority: local-admin. */
public final class ConversationAttachmentUploadRequest implements WireValue {
    private final Field<UInt64> byteCount;
    private final Field<String> conversation;
    private final Field<String> data;
    private final Field<UInt64> durationMs;
    private final Field<Long> height;
    private final Field<String> mimeType;
    private final Field<String> name;
    private final Field<UInt64> offset;
    private final String op;
    private final Field<String> piece;
    private final Field<Object> poster;
    private final Field<Object> preview;
    private final Field<String> sha256;
    private final Field<String> upload;
    private final Field<Long> width;

    private ConversationAttachmentUploadRequest(Builder builder) {
        this.byteCount = builder.byteCount;
        this.conversation = builder.conversation;
        this.data = builder.data;
        this.durationMs = builder.durationMs;
        this.height = builder.height;
        this.mimeType = builder.mimeType;
        this.name = builder.name;
        this.offset = builder.offset;
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        this.piece = builder.piece;
        this.poster = builder.poster.map(value -> Wire.immutableJson(value));
        this.preview = builder.preview.map(value -> Wire.immutableJson(value));
        this.sha256 = builder.sha256;
        this.upload = builder.upload;
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> byteCount() { return byteCount; }
    public Field<String> conversation() { return conversation; }
    public Field<String> data() { return data; }
    public Field<UInt64> durationMs() { return durationMs; }
    public Field<Long> height() { return height; }
    public Field<String> mimeType() { return mimeType; }
    public Field<String> name() { return name; }
    public Field<UInt64> offset() { return offset; }
    public String op() { return op; }
    public Field<String> piece() { return piece; }
    public Field<Object> poster() { return poster; }
    public Field<Object> preview() { return preview; }
    public Field<String> sha256() { return sha256; }
    public Field<String> upload() { return upload; }
    public Field<Long> width() { return width; }

    public static ConversationAttachmentUploadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentUploadRequest");
        Builder builder = builder();
        Object rawByteCount = Wire.optional(object, "byte_count");
        if (!Wire.isMissing(rawByteCount)) {
            builder.byteCount(rawByteCount == null ? null : Wire.uint64(rawByteCount, "ConversationAttachmentUploadRequest.byte_count"));
        }
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "ConversationAttachmentUploadRequest.conversation"));
        }
        Object rawData = Wire.optional(object, "data");
        if (!Wire.isMissing(rawData)) {
            builder.data(rawData == null ? null : Wire.string(rawData, "ConversationAttachmentUploadRequest.data"));
        }
        Object rawDurationMs = Wire.optional(object, "duration_ms");
        if (!Wire.isMissing(rawDurationMs)) {
            builder.durationMs(rawDurationMs == null ? null : Wire.uint64(rawDurationMs, "ConversationAttachmentUploadRequest.duration_ms"));
        }
        Object rawHeight = Wire.optional(object, "height");
        if (!Wire.isMissing(rawHeight)) {
            builder.height(rawHeight == null ? null : Wire.uint32(rawHeight, "ConversationAttachmentUploadRequest.height"));
        }
        Object rawMimeType = Wire.optional(object, "mime_type");
        if (!Wire.isMissing(rawMimeType)) {
            builder.mimeType(rawMimeType == null ? null : Wire.string(rawMimeType, "ConversationAttachmentUploadRequest.mime_type"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "ConversationAttachmentUploadRequest.name"));
        }
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(rawOffset == null ? null : Wire.uint64(rawOffset, "ConversationAttachmentUploadRequest.offset"));
        }
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "ConversationAttachmentUploadRequest.op"));
        Object rawPiece = Wire.optional(object, "piece");
        if (!Wire.isMissing(rawPiece)) {
            builder.piece(rawPiece == null ? null : Wire.string(rawPiece, "ConversationAttachmentUploadRequest.piece"));
        }
        Object rawPoster = Wire.optional(object, "poster");
        if (!Wire.isMissing(rawPoster)) {
            builder.poster(rawPoster == null ? null : Wire.immutableJson(rawPoster));
        }
        Object rawPreview = Wire.optional(object, "preview");
        if (!Wire.isMissing(rawPreview)) {
            builder.preview(rawPreview == null ? null : Wire.immutableJson(rawPreview));
        }
        Object rawSha256 = Wire.optional(object, "sha256");
        if (!Wire.isMissing(rawSha256)) {
            builder.sha256(rawSha256 == null ? null : Wire.string(rawSha256, "ConversationAttachmentUploadRequest.sha256"));
        }
        Object rawUpload = Wire.optional(object, "upload");
        if (!Wire.isMissing(rawUpload)) {
            builder.upload(rawUpload == null ? null : Wire.string(rawUpload, "ConversationAttachmentUploadRequest.upload"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.uint32(rawWidth, "ConversationAttachmentUploadRequest.width"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "byte_count", byteCount);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "data", data);
        Wire.put(object, "duration_ms", durationMs);
        Wire.put(object, "height", height);
        Wire.put(object, "mime_type", mimeType);
        Wire.put(object, "name", name);
        Wire.put(object, "offset", offset);
        Wire.put(object, "op", op);
        Wire.put(object, "piece", piece);
        Wire.put(object, "poster", poster);
        Wire.put(object, "preview", preview);
        Wire.put(object, "sha256", sha256);
        Wire.put(object, "upload", upload);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentUploadRequest that)) return false;
        return Objects.equals(byteCount, that.byteCount) && Objects.equals(conversation, that.conversation) && Objects.equals(data, that.data) && Objects.equals(durationMs, that.durationMs) && Objects.equals(height, that.height) && Objects.equals(mimeType, that.mimeType) && Objects.equals(name, that.name) && Objects.equals(offset, that.offset) && Objects.equals(op, that.op) && Objects.equals(piece, that.piece) && Objects.equals(poster, that.poster) && Objects.equals(preview, that.preview) && Objects.equals(sha256, that.sha256) && Objects.equals(upload, that.upload) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(byteCount, conversation, data, durationMs, height, mimeType, name, offset, op, piece, poster, preview, sha256, upload, width); }

    @Override
    public String toString() { return "ConversationAttachmentUploadRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> byteCount = Field.omitted();
        private Field<String> conversation = Field.omitted();
        private Field<String> data = Field.omitted();
        private Field<UInt64> durationMs = Field.omitted();
        private Field<Long> height = Field.omitted();
        private Field<String> mimeType = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<UInt64> offset = Field.omitted();
        private String op;
        private boolean opSet;
        private Field<String> piece = Field.omitted();
        private Field<Object> poster = Field.omitted();
        private Field<Object> preview = Field.omitted();
        private Field<String> sha256 = Field.omitted();
        private Field<String> upload = Field.omitted();
        private Field<Long> width = Field.omitted();

        public Builder byteCount(UInt64 value) {
            this.byteCount = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
            return this;
        }
        public Builder data(String value) {
            this.data = Field.ofNullable(value);
            return this;
        }
        public Builder durationMs(UInt64 value) {
            this.durationMs = Field.ofNullable(value);
            return this;
        }
        public Builder height(Long value) {
            this.height = Field.ofNullable(value);
            return this;
        }
        public Builder mimeType(String value) {
            this.mimeType = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
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
        public Builder piece(String value) {
            this.piece = Field.ofNullable(value);
            return this;
        }
        public Builder poster(Object value) {
            this.poster = Field.ofNullable(value);
            return this;
        }
        public Builder preview(Object value) {
            this.preview = Field.ofNullable(value);
            return this;
        }
        public Builder sha256(String value) {
            this.sha256 = Field.ofNullable(value);
            return this;
        }
        public Builder upload(String value) {
            this.upload = Field.ofNullable(value);
            return this;
        }
        public Builder width(Long value) {
            this.width = Field.ofNullable(value);
            return this;
        }
        public ConversationAttachmentUploadRequest build() { return new ConversationAttachmentUploadRequest(this); }
    }
}
