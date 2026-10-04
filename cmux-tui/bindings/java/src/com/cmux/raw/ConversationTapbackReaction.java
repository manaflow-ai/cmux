// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTapbackReaction implements WireValue {
    private final ConversationTapback tapback;

    private ConversationTapbackReaction(Builder builder) {
        if (!builder.tapbackSet) throw new IllegalArgumentException("tapback is required");
        this.tapback = Wire.nonNull(builder.tapback, "tapback");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationTapback tapback() { return tapback; }

    public static ConversationTapbackReaction fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTapbackReaction");
        Builder builder = builder();
        Object rawTapback = Wire.required(object, "tapback");
        builder.tapback(ConversationTapback.fromWire(rawTapback));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "tapback", tapback);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTapbackReaction that)) return false;
        return Objects.equals(tapback, that.tapback);
    }

    @Override
    public int hashCode() { return Objects.hash(tapback); }

    @Override
    public String toString() { return "ConversationTapbackReaction" + toWire(); }

    public static final class Builder {
        private ConversationTapback tapback;
        private boolean tapbackSet;

        public Builder tapback(ConversationTapback value) {
            this.tapback = value;
            this.tapbackSet = true;
            return this;
        }
        public ConversationTapbackReaction build() { return new ConversationTapbackReaction(this); }
    }
}
