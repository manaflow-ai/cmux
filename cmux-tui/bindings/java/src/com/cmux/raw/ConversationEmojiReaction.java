// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationEmojiReaction implements WireValue {
    private final String emoji;

    private ConversationEmojiReaction(Builder builder) {
        if (!builder.emojiSet) throw new IllegalArgumentException("emoji is required");
        this.emoji = Wire.nonNull(builder.emoji, "emoji");
    }

    public static Builder builder() { return new Builder(); }

    public String emoji() { return emoji; }

    public static ConversationEmojiReaction fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationEmojiReaction");
        Builder builder = builder();
        Object rawEmoji = Wire.required(object, "emoji");
        builder.emoji(Wire.string(rawEmoji, "ConversationEmojiReaction.emoji"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "emoji", emoji);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationEmojiReaction that)) return false;
        return Objects.equals(emoji, that.emoji);
    }

    @Override
    public int hashCode() { return Objects.hash(emoji); }

    @Override
    public String toString() { return "ConversationEmojiReaction" + toWire(); }

    public static final class Builder {
        private String emoji;
        private boolean emojiSet;

        public Builder emoji(String value) {
            this.emoji = value;
            this.emojiSet = true;
            return this;
        }
        public ConversationEmojiReaction build() { return new ConversationEmojiReaction(this); }
    }
}
