// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationQuestionSelection implements WireValue {
    private final Field<List<String>> optionIds;
    private final Field<String> other;

    private ConversationQuestionSelection(Builder builder) {
        this.optionIds = builder.optionIds.map(value -> List.copyOf(value));
        this.other = builder.other;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> optionIds() { return optionIds; }
    public Field<String> other() { return other; }

    public static ConversationQuestionSelection fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationQuestionSelection");
        Builder builder = builder();
        Object rawOptionIds = Wire.optional(object, "option_ids");
        if (!Wire.isMissing(rawOptionIds)) {
            builder.optionIds(Wire.array(rawOptionIds, "ConversationQuestionSelection.option_ids", item -> Wire.string(item, "ConversationQuestionSelection.option_ids item")));
        }
        Object rawOther = Wire.optional(object, "other");
        if (!Wire.isMissing(rawOther)) {
            builder.other(rawOther == null ? null : Wire.string(rawOther, "ConversationQuestionSelection.other"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "option_ids", optionIds);
        Wire.put(object, "other", other);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationQuestionSelection that)) return false;
        return Objects.equals(optionIds, that.optionIds) && Objects.equals(other, that.other);
    }

    @Override
    public int hashCode() { return Objects.hash(optionIds, other); }

    @Override
    public String toString() { return "ConversationQuestionSelection" + toWire(); }

    public static final class Builder {
        private Field<List<String>> optionIds = Field.omitted();
        private Field<String> other = Field.omitted();

        public Builder optionIds(List<String> value) {
            this.optionIds = Field.of(value);
            return this;
        }
        public Builder other(String value) {
            this.other = Field.ofNullable(value);
            return this;
        }
        public ConversationQuestionSelection build() { return new ConversationQuestionSelection(this); }
    }
}
