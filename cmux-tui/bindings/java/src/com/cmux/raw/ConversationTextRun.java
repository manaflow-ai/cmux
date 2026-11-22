// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTextRun implements WireValue {
    private final long length;
    private final Field<String> link;
    private final Field<String> mention;
    private final long start;

    private ConversationTextRun(Builder builder) {
        if (!builder.lengthSet) throw new IllegalArgumentException("length is required");
        this.length = builder.length;
        this.link = builder.link;
        this.mention = builder.mention;
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = builder.start;
    }

    public static Builder builder() { return new Builder(); }

    public long length() { return length; }
    public Field<String> link() { return link; }
    public Field<String> mention() { return mention; }
    public long start() { return start; }

    public static ConversationTextRun fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTextRun");
        Builder builder = builder();
        Object rawLength = Wire.required(object, "length");
        builder.length(Wire.uint32(rawLength, "ConversationTextRun.length"));
        Object rawLink = Wire.optional(object, "link");
        if (!Wire.isMissing(rawLink)) {
            builder.link(Wire.string(rawLink, "ConversationTextRun.link"));
        }
        Object rawMention = Wire.optional(object, "mention");
        if (!Wire.isMissing(rawMention)) {
            builder.mention(Wire.string(rawMention, "ConversationTextRun.mention"));
        }
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint32(rawStart, "ConversationTextRun.start"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "length", length);
        Wire.put(object, "link", link);
        Wire.put(object, "mention", mention);
        Wire.put(object, "start", start);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTextRun that)) return false;
        return Objects.equals(length, that.length) && Objects.equals(link, that.link) && Objects.equals(mention, that.mention) && Objects.equals(start, that.start);
    }

    @Override
    public int hashCode() { return Objects.hash(length, link, mention, start); }

    @Override
    public String toString() { return "ConversationTextRun" + toWire(); }

    public static final class Builder {
        private Long length;
        private boolean lengthSet;
        private Field<String> link = Field.omitted();
        private Field<String> mention = Field.omitted();
        private Long start;
        private boolean startSet;

        public Builder length(long value) {
            this.length = value;
            this.lengthSet = true;
            return this;
        }
        public Builder link(String value) {
            this.link = Field.of(value);
            return this;
        }
        public Builder mention(String value) {
            this.mention = Field.of(value);
            return this;
        }
        public Builder start(long value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public ConversationTextRun build() { return new ConversationTextRun(this); }
    }
}
