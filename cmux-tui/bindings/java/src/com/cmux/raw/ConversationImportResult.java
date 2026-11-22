// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationImportResult implements WireValue {
    private final ConversationSummary conversation;
    private final List<UInt64> imported;
    private final UInt64 skipped;

    private ConversationImportResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.importedSet) throw new IllegalArgumentException("imported is required");
        this.imported = List.copyOf(Wire.nonNull(builder.imported, "imported"));
        if (!builder.skippedSet) throw new IllegalArgumentException("skipped is required");
        this.skipped = Wire.nonNull(builder.skipped, "skipped");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationSummary conversation() { return conversation; }
    public List<UInt64> imported() { return imported; }
    public UInt64 skipped() { return skipped; }

    public static ConversationImportResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationImportResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationSummary.fromWire(rawConversation));
        Object rawImported = Wire.required(object, "imported");
        builder.imported(Wire.array(rawImported, "ConversationImportResult.imported", item -> Wire.uint64(item, "ConversationImportResult.imported item")));
        Object rawSkipped = Wire.required(object, "skipped");
        builder.skipped(Wire.uint64(rawSkipped, "ConversationImportResult.skipped"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "imported", imported);
        Wire.put(object, "skipped", skipped);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationImportResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(imported, that.imported) && Objects.equals(skipped, that.skipped);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, imported, skipped); }

    @Override
    public String toString() { return "ConversationImportResult" + toWire(); }

    public static final class Builder {
        private ConversationSummary conversation;
        private boolean conversationSet;
        private List<UInt64> imported;
        private boolean importedSet;
        private UInt64 skipped;
        private boolean skippedSet;

        public Builder conversation(ConversationSummary value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder imported(List<UInt64> value) {
            this.imported = value;
            this.importedSet = true;
            return this;
        }
        public Builder skipped(UInt64 value) {
            this.skipped = value;
            this.skippedSet = true;
            return this;
        }
        public ConversationImportResult build() { return new ConversationImportResult(this); }
    }
}
