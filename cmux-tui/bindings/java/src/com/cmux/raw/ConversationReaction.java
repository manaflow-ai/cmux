// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationReaction implements WireValue {
    private final String at;
    private final String author;
    private final ConversationReactionKind kind;
    private final long partIndex;

    private ConversationReaction(Builder builder) {
        if (!builder.atSet) throw new IllegalArgumentException("at is required");
        this.at = Wire.nonNull(builder.at, "at");
        if (!builder.authorSet) throw new IllegalArgumentException("author is required");
        this.author = Wire.nonNull(builder.author, "author");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.partIndexSet) throw new IllegalArgumentException("part_index is required");
        this.partIndex = builder.partIndex;
    }

    public static Builder builder() { return new Builder(); }

    public String at() { return at; }
    public String author() { return author; }
    public ConversationReactionKind kind() { return kind; }
    public long partIndex() { return partIndex; }

    public static ConversationReaction fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationReaction");
        Builder builder = builder();
        Object rawAt = Wire.required(object, "at");
        builder.at(Wire.string(rawAt, "ConversationReaction.at"));
        Object rawAuthor = Wire.required(object, "author");
        builder.author(Wire.string(rawAuthor, "ConversationReaction.author"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(ConversationReactionKind.fromWire(rawKind));
        Object rawPartIndex = Wire.required(object, "part_index");
        builder.partIndex(Wire.uint32(rawPartIndex, "ConversationReaction.part_index"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "at", at);
        Wire.put(object, "author", author);
        Wire.put(object, "kind", kind);
        Wire.put(object, "part_index", partIndex);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationReaction that)) return false;
        return Objects.equals(at, that.at) && Objects.equals(author, that.author) && Objects.equals(kind, that.kind) && Objects.equals(partIndex, that.partIndex);
    }

    @Override
    public int hashCode() { return Objects.hash(at, author, kind, partIndex); }

    @Override
    public String toString() { return "ConversationReaction" + toWire(); }

    public static final class Builder {
        private String at;
        private boolean atSet;
        private String author;
        private boolean authorSet;
        private ConversationReactionKind kind;
        private boolean kindSet;
        private Long partIndex;
        private boolean partIndexSet;

        public Builder at(String value) {
            this.at = value;
            this.atSet = true;
            return this;
        }
        public Builder author(String value) {
            this.author = value;
            this.authorSet = true;
            return this;
        }
        public Builder kind(ConversationReactionKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder partIndex(long value) {
            this.partIndex = value;
            this.partIndexSet = true;
            return this;
        }
        public ConversationReaction build() { return new ConversationReaction(this); }
    }
}
