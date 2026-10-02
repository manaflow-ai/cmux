// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-conversation-tab request. Protocol v12; authority: control. */
public final class NewConversationTabRequest implements WireValue {
    private final Field<Integer> cols;
    private final String conversation;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final String owner;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;

    private NewConversationTabRequest(Builder builder) {
        this.cols = builder.cols;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
        this.pane = builder.pane;
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public String conversation() { return conversation; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public String owner() { return owner; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }

    public static NewConversationTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewConversationTabRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewConversationTabRequest.cols"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "NewConversationTabRequest.conversation"));
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "NewConversationTabRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "NewConversationTabRequest.origin"));
        }
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "NewConversationTabRequest.owner"));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewConversationTabRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewConversationTabRequest.rows"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "owner", owner);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewConversationTabRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(conversation, that.conversation) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(owner, that.owner) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, conversation, mutationId, origin, owner, pane, rows); }

    @Override
    public String toString() { return "NewConversationTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private String owner;
        private boolean ownerSet;
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public NewConversationTabRequest build() { return new NewConversationTabRequest(this); }
    }
}
