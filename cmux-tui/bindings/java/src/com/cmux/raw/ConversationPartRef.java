// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationPartRef implements WireValue {
    private final String messageId;
    private final long partIndex;

    private ConversationPartRef(Builder builder) {
        if (!builder.messageIdSet) throw new IllegalArgumentException("message_id is required");
        this.messageId = Wire.nonNull(builder.messageId, "message_id");
        if (!builder.partIndexSet) throw new IllegalArgumentException("part_index is required");
        this.partIndex = builder.partIndex;
    }

    public static Builder builder() { return new Builder(); }

    public String messageId() { return messageId; }
    public long partIndex() { return partIndex; }

    public static ConversationPartRef fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationPartRef");
        Builder builder = builder();
        Object rawMessageId = Wire.required(object, "message_id");
        builder.messageId(Wire.string(rawMessageId, "ConversationPartRef.message_id"));
        Object rawPartIndex = Wire.required(object, "part_index");
        builder.partIndex(Wire.uint32(rawPartIndex, "ConversationPartRef.part_index"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "message_id", messageId);
        Wire.put(object, "part_index", partIndex);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationPartRef that)) return false;
        return Objects.equals(messageId, that.messageId) && Objects.equals(partIndex, that.partIndex);
    }

    @Override
    public int hashCode() { return Objects.hash(messageId, partIndex); }

    @Override
    public String toString() { return "ConversationPartRef" + toWire(); }

    public static final class Builder {
        private String messageId;
        private boolean messageIdSet;
        private Long partIndex;
        private boolean partIndexSet;

        public Builder messageId(String value) {
            this.messageId = value;
            this.messageIdSet = true;
            return this;
        }
        public Builder partIndex(long value) {
            this.partIndex = value;
            this.partIndexSet = true;
            return this;
        }
        public ConversationPartRef build() { return new ConversationPartRef(this); }
    }
}
