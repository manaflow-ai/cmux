// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationAttachmentUploadResult implements WireValue {
    private final Field<List<String>> needs;
    private final Field<UInt64> received;
    private final Field<ConversationAttachmentUploadResultStored> stored;
    private final Field<String> upload;

    private ConversationAttachmentUploadResult(Builder builder) {
        this.needs = builder.needs.map(value -> List.copyOf(value));
        this.received = builder.received;
        this.stored = builder.stored;
        this.upload = builder.upload;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> needs() { return needs; }
    public Field<UInt64> received() { return received; }
    public Field<ConversationAttachmentUploadResultStored> stored() { return stored; }
    public Field<String> upload() { return upload; }

    public static ConversationAttachmentUploadResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationAttachmentUploadResult");
        Builder builder = builder();
        Object rawNeeds = Wire.optional(object, "needs");
        if (!Wire.isMissing(rawNeeds)) {
            builder.needs(rawNeeds == null ? null : Wire.array(rawNeeds, "ConversationAttachmentUploadResult.needs", item -> Wire.string(item, "ConversationAttachmentUploadResult.needs item")));
        }
        Object rawReceived = Wire.optional(object, "received");
        if (!Wire.isMissing(rawReceived)) {
            builder.received(rawReceived == null ? null : Wire.uint64(rawReceived, "ConversationAttachmentUploadResult.received"));
        }
        Object rawStored = Wire.optional(object, "stored");
        if (!Wire.isMissing(rawStored)) {
            builder.stored(rawStored == null ? null : ConversationAttachmentUploadResultStored.fromWire(rawStored));
        }
        Object rawUpload = Wire.optional(object, "upload");
        if (!Wire.isMissing(rawUpload)) {
            builder.upload(rawUpload == null ? null : Wire.string(rawUpload, "ConversationAttachmentUploadResult.upload"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "needs", needs);
        Wire.put(object, "received", received);
        Wire.put(object, "stored", stored);
        Wire.put(object, "upload", upload);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationAttachmentUploadResult that)) return false;
        return Objects.equals(needs, that.needs) && Objects.equals(received, that.received) && Objects.equals(stored, that.stored) && Objects.equals(upload, that.upload);
    }

    @Override
    public int hashCode() { return Objects.hash(needs, received, stored, upload); }

    @Override
    public String toString() { return "ConversationAttachmentUploadResult" + toWire(); }

    public static final class Builder {
        private Field<List<String>> needs = Field.omitted();
        private Field<UInt64> received = Field.omitted();
        private Field<ConversationAttachmentUploadResultStored> stored = Field.omitted();
        private Field<String> upload = Field.omitted();

        public Builder needs(List<String> value) {
            this.needs = Field.ofNullable(value);
            return this;
        }
        public Builder received(UInt64 value) {
            this.received = Field.ofNullable(value);
            return this;
        }
        public Builder stored(ConversationAttachmentUploadResultStored value) {
            this.stored = Field.ofNullable(value);
            return this;
        }
        public Builder upload(String value) {
            this.upload = Field.ofNullable(value);
            return this;
        }
        public ConversationAttachmentUploadResult build() { return new ConversationAttachmentUploadResult(this); }
    }
}
