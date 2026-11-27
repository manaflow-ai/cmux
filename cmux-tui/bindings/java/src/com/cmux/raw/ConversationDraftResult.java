// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationDraftResult implements WireValue {
    private final boolean published;

    private ConversationDraftResult(Builder builder) {
        if (!builder.publishedSet) throw new IllegalArgumentException("published is required");
        this.published = builder.published;
    }

    public static Builder builder() { return new Builder(); }

    public boolean published() { return published; }

    public static ConversationDraftResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationDraftResult");
        Builder builder = builder();
        Object rawPublished = Wire.required(object, "published");
        builder.published(Wire.bool(rawPublished, "ConversationDraftResult.published"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "published", published);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationDraftResult that)) return false;
        return Objects.equals(published, that.published);
    }

    @Override
    public int hashCode() { return Objects.hash(published); }

    @Override
    public String toString() { return "ConversationDraftResult" + toWire(); }

    public static final class Builder {
        private Boolean published;
        private boolean publishedSet;

        public Builder published(boolean value) {
            this.published = value;
            this.publishedSet = true;
            return this;
        }
        public ConversationDraftResult build() { return new ConversationDraftResult(this); }
    }
}
