// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationImportMessage implements WireValue {
    private final String author;
    private final String clientMsgId;
    private final String createdAt;
    private final Field<String> id;
    private final List<ConversationPart> parts;

    private ConversationImportMessage(Builder builder) {
        if (!builder.authorSet) throw new IllegalArgumentException("author is required");
        this.author = Wire.nonNull(builder.author, "author");
        if (!builder.clientMsgIdSet) throw new IllegalArgumentException("client_msg_id is required");
        this.clientMsgId = Wire.nonNull(builder.clientMsgId, "client_msg_id");
        if (!builder.createdAtSet) throw new IllegalArgumentException("created_at is required");
        this.createdAt = Wire.nonNull(builder.createdAt, "created_at");
        this.id = builder.id;
        if (!builder.partsSet) throw new IllegalArgumentException("parts is required");
        this.parts = List.copyOf(Wire.nonNull(builder.parts, "parts"));
    }

    public static Builder builder() { return new Builder(); }

    public String author() { return author; }
    public String clientMsgId() { return clientMsgId; }
    public String createdAt() { return createdAt; }
    public Field<String> id() { return id; }
    public List<ConversationPart> parts() { return parts; }

    public static ConversationImportMessage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationImportMessage");
        Builder builder = builder();
        Object rawAuthor = Wire.required(object, "author");
        builder.author(Wire.string(rawAuthor, "ConversationImportMessage.author"));
        Object rawClientMsgId = Wire.required(object, "client_msg_id");
        builder.clientMsgId(Wire.string(rawClientMsgId, "ConversationImportMessage.client_msg_id"));
        Object rawCreatedAt = Wire.required(object, "created_at");
        builder.createdAt(Wire.string(rawCreatedAt, "ConversationImportMessage.created_at"));
        Object rawId = Wire.optional(object, "id");
        if (!Wire.isMissing(rawId)) {
            builder.id(rawId == null ? null : Wire.string(rawId, "ConversationImportMessage.id"));
        }
        Object rawParts = Wire.required(object, "parts");
        builder.parts(Wire.array(rawParts, "ConversationImportMessage.parts", item -> ConversationPart.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "author", author);
        Wire.put(object, "client_msg_id", clientMsgId);
        Wire.put(object, "created_at", createdAt);
        Wire.put(object, "id", id);
        Wire.put(object, "parts", parts);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationImportMessage that)) return false;
        return Objects.equals(author, that.author) && Objects.equals(clientMsgId, that.clientMsgId) && Objects.equals(createdAt, that.createdAt) && Objects.equals(id, that.id) && Objects.equals(parts, that.parts);
    }

    @Override
    public int hashCode() { return Objects.hash(author, clientMsgId, createdAt, id, parts); }

    @Override
    public String toString() { return "ConversationImportMessage" + toWire(); }

    public static final class Builder {
        private String author;
        private boolean authorSet;
        private String clientMsgId;
        private boolean clientMsgIdSet;
        private String createdAt;
        private boolean createdAtSet;
        private Field<String> id = Field.omitted();
        private List<ConversationPart> parts;
        private boolean partsSet;

        public Builder author(String value) {
            this.author = value;
            this.authorSet = true;
            return this;
        }
        public Builder clientMsgId(String value) {
            this.clientMsgId = value;
            this.clientMsgIdSet = true;
            return this;
        }
        public Builder createdAt(String value) {
            this.createdAt = value;
            this.createdAtSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = Field.ofNullable(value);
            return this;
        }
        public Builder parts(List<ConversationPart> value) {
            this.parts = value;
            this.partsSet = true;
            return this;
        }
        public ConversationImportMessage build() { return new ConversationImportMessage(this); }
    }
}
