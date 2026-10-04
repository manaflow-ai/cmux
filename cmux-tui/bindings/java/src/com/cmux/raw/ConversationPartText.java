// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationPartText implements WireValue, ConversationPart {
    private final Field<List<ConversationTextRun>> runs;
    private final String text;

    private ConversationPartText(Builder builder) {
        this.runs = builder.runs.map(value -> List.copyOf(value));
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<ConversationTextRun>> runs() { return runs; }
    public String text() { return text; }
    public String type() { return "text"; }

    public static ConversationPartText fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationPartText");
        Builder builder = builder();
        Object rawRuns = Wire.optional(object, "runs");
        if (!Wire.isMissing(rawRuns)) {
            builder.runs(Wire.array(rawRuns, "ConversationPartText.runs", item -> ConversationTextRun.fromWire(item)));
        }
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "ConversationPartText.text"));
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "text", "ConversationPartText.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "runs", runs);
        Wire.put(object, "text", text);
        Wire.put(object, "type", "text");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationPartText that)) return false;
        return Objects.equals(runs, that.runs) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(runs, text); }

    @Override
    public String toString() { return "ConversationPartText" + toWire(); }

    public static final class Builder {
        private Field<List<ConversationTextRun>> runs = Field.omitted();
        private String text;
        private boolean textSet;

        public Builder runs(List<ConversationTextRun> value) {
            this.runs = Field.of(value);
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public ConversationPartText build() { return new ConversationPartText(this); }
    }
}
