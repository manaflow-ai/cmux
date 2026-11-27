// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationQuestionAnswer implements WireValue {
    private final Field<String> answeredAt;
    private final Field<ConversationQuestionRespondent> respondent;
    private final Map<String, ConversationQuestionSelection> selections;

    private ConversationQuestionAnswer(Builder builder) {
        this.answeredAt = builder.answeredAt;
        this.respondent = builder.respondent;
        if (!builder.selectionsSet) throw new IllegalArgumentException("selections is required");
        this.selections = Collections.unmodifiableMap(new LinkedHashMap<>(Wire.nonNull(builder.selections, "selections")));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> answeredAt() { return answeredAt; }
    public Field<ConversationQuestionRespondent> respondent() { return respondent; }
    public Map<String, ConversationQuestionSelection> selections() { return selections; }

    public static ConversationQuestionAnswer fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationQuestionAnswer");
        Builder builder = builder();
        Object rawAnsweredAt = Wire.optional(object, "answered_at");
        if (!Wire.isMissing(rawAnsweredAt)) {
            builder.answeredAt(rawAnsweredAt == null ? null : Wire.string(rawAnsweredAt, "ConversationQuestionAnswer.answered_at"));
        }
        Object rawRespondent = Wire.optional(object, "respondent");
        if (!Wire.isMissing(rawRespondent)) {
            builder.respondent(rawRespondent == null ? null : ConversationQuestionRespondent.fromWire(rawRespondent));
        }
        Object rawSelections = Wire.required(object, "selections");
        builder.selections(Wire.map(rawSelections, "ConversationQuestionAnswer.selections", item -> ConversationQuestionSelection.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "answered_at", answeredAt);
        Wire.put(object, "respondent", respondent);
        Wire.put(object, "selections", selections);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationQuestionAnswer that)) return false;
        return Objects.equals(answeredAt, that.answeredAt) && Objects.equals(respondent, that.respondent) && Objects.equals(selections, that.selections);
    }

    @Override
    public int hashCode() { return Objects.hash(answeredAt, respondent, selections); }

    @Override
    public String toString() { return "ConversationQuestionAnswer" + toWire(); }

    public static final class Builder {
        private Field<String> answeredAt = Field.omitted();
        private Field<ConversationQuestionRespondent> respondent = Field.omitted();
        private Map<String, ConversationQuestionSelection> selections;
        private boolean selectionsSet;

        public Builder answeredAt(String value) {
            this.answeredAt = Field.ofNullable(value);
            return this;
        }
        public Builder respondent(ConversationQuestionRespondent value) {
            this.respondent = Field.ofNullable(value);
            return this;
        }
        public Builder selections(Map<String, ConversationQuestionSelection> value) {
            this.selections = value;
            this.selectionsSet = true;
            return this;
        }
        public ConversationQuestionAnswer build() { return new ConversationQuestionAnswer(this); }
    }
}
