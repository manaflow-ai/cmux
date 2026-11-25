// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationScheduledListResult implements WireValue {
    private final List<Object> scheduled;

    private ConversationScheduledListResult(Builder builder) {
        if (!builder.scheduledSet) throw new IllegalArgumentException("scheduled is required");
        this.scheduled = List.copyOf(Wire.nonNull(builder.scheduled, "scheduled"));
    }

    public static Builder builder() { return new Builder(); }

    public List<Object> scheduled() { return scheduled; }

    public static ConversationScheduledListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationScheduledListResult");
        Builder builder = builder();
        Object rawScheduled = Wire.required(object, "scheduled");
        builder.scheduled(Wire.array(rawScheduled, "ConversationScheduledListResult.scheduled", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "scheduled", scheduled);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationScheduledListResult that)) return false;
        return Objects.equals(scheduled, that.scheduled);
    }

    @Override
    public int hashCode() { return Objects.hash(scheduled); }

    @Override
    public String toString() { return "ConversationScheduledListResult" + toWire(); }

    public static final class Builder {
        private List<Object> scheduled;
        private boolean scheduledSet;

        public Builder scheduled(List<Object> value) {
            this.scheduled = value;
            this.scheduledSet = true;
            return this;
        }
        public ConversationScheduledListResult build() { return new ConversationScheduledListResult(this); }
    }
}
