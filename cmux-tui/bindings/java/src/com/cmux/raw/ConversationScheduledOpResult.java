// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationScheduledOpResult implements WireValue {
    private final Field<Object> change;
    private final Field<Object> removed;
    private final Field<Boolean> replayed;
    private final Field<UInt64> rev;
    private final Field<Object> scheduled;

    private ConversationScheduledOpResult(Builder builder) {
        this.change = builder.change.map(value -> Wire.immutableJson(value));
        this.removed = builder.removed.map(value -> Wire.immutableJson(value));
        this.replayed = builder.replayed;
        this.rev = builder.rev;
        this.scheduled = builder.scheduled.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> change() { return change; }
    public Field<Object> removed() { return removed; }
    public Field<Boolean> replayed() { return replayed; }
    public Field<UInt64> rev() { return rev; }
    public Field<Object> scheduled() { return scheduled; }

    public static ConversationScheduledOpResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationScheduledOpResult");
        Builder builder = builder();
        Object rawChange = Wire.optional(object, "change");
        if (!Wire.isMissing(rawChange)) {
            builder.change(Wire.immutableJson(rawChange));
        }
        Object rawRemoved = Wire.optional(object, "removed");
        if (!Wire.isMissing(rawRemoved)) {
            builder.removed(Wire.immutableJson(rawRemoved));
        }
        Object rawReplayed = Wire.optional(object, "replayed");
        if (!Wire.isMissing(rawReplayed)) {
            builder.replayed(Wire.bool(rawReplayed, "ConversationScheduledOpResult.replayed"));
        }
        Object rawRev = Wire.optional(object, "rev");
        if (!Wire.isMissing(rawRev)) {
            builder.rev(Wire.uint64(rawRev, "ConversationScheduledOpResult.rev"));
        }
        Object rawScheduled = Wire.optional(object, "scheduled");
        if (!Wire.isMissing(rawScheduled)) {
            builder.scheduled(rawScheduled == null ? null : Wire.immutableJson(rawScheduled));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "change", change);
        Wire.put(object, "removed", removed);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "rev", rev);
        Wire.put(object, "scheduled", scheduled);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationScheduledOpResult that)) return false;
        return Objects.equals(change, that.change) && Objects.equals(removed, that.removed) && Objects.equals(replayed, that.replayed) && Objects.equals(rev, that.rev) && Objects.equals(scheduled, that.scheduled);
    }

    @Override
    public int hashCode() { return Objects.hash(change, removed, replayed, rev, scheduled); }

    @Override
    public String toString() { return "ConversationScheduledOpResult" + toWire(); }

    public static final class Builder {
        private Field<Object> change = Field.omitted();
        private Field<Object> removed = Field.omitted();
        private Field<Boolean> replayed = Field.omitted();
        private Field<UInt64> rev = Field.omitted();
        private Field<Object> scheduled = Field.omitted();

        public Builder change(Object value) {
            this.change = Field.of(value);
            return this;
        }
        public Builder removed(Object value) {
            this.removed = Field.of(value);
            return this;
        }
        public Builder replayed(Boolean value) {
            this.replayed = Field.of(value);
            return this;
        }
        public Builder rev(UInt64 value) {
            this.rev = Field.of(value);
            return this;
        }
        public Builder scheduled(Object value) {
            this.scheduled = Field.ofNullable(value);
            return this;
        }
        public ConversationScheduledOpResult build() { return new ConversationScheduledOpResult(this); }
    }
}
