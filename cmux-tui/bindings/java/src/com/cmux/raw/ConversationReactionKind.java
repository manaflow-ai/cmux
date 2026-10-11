// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationReactionKind implements WireValue {
    private final Field<String> emoji;
    /** Known values: love, like, dislike, laugh, emphasize, question. */
    private final Field<String> tapback;
    private final Map<String, Object> additionalProperties;

    private ConversationReactionKind(Builder builder) {
        this.emoji = builder.emoji;
        this.tapback = builder.tapback;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> emoji() { return emoji; }
    public Field<String> tapback() { return tapback; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ConversationReactionKind fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationReactionKind");
        Builder builder = builder();
        Object rawEmoji = Wire.optional(object, "emoji");
        if (!Wire.isMissing(rawEmoji)) {
            builder.emoji(Wire.string(rawEmoji, "ConversationReactionKind.emoji"));
        }
        Object rawTapback = Wire.optional(object, "tapback");
        if (!Wire.isMissing(rawTapback)) {
            builder.tapback(Wire.string(rawTapback, "ConversationReactionKind.tapback"));
        }
        List<String> known = List.of("emoji", "tapback");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "emoji", emoji);
        Wire.put(object, "tapback", tapback);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationReactionKind that)) return false;
        return Objects.equals(emoji, that.emoji) && Objects.equals(tapback, that.tapback) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(emoji, tapback, additionalProperties); }

    @Override
    public String toString() { return "ConversationReactionKind" + toWire(); }

    public static final class Builder {
        private Field<String> emoji = Field.omitted();
        private Field<String> tapback = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder emoji(String value) {
            this.emoji = Field.of(value);
            return this;
        }
        public Builder tapback(String value) {
            this.tapback = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ConversationReactionKind build() { return new ConversationReactionKind(this); }
    }
}
