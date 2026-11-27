// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationThreadState implements WireValue {
    private final Field<String> owner;
    private final Field<ConversationThreadResolution> resolved;
    private final Field<String> title;

    private ConversationThreadState(Builder builder) {
        this.owner = builder.owner;
        this.resolved = builder.resolved;
        this.title = builder.title;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> owner() { return owner; }
    public Field<ConversationThreadResolution> resolved() { return resolved; }
    public Field<String> title() { return title; }

    public static ConversationThreadState fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadState");
        Builder builder = builder();
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(Wire.string(rawOwner, "ConversationThreadState.owner"));
        }
        Object rawResolved = Wire.optional(object, "resolved");
        if (!Wire.isMissing(rawResolved)) {
            builder.resolved(ConversationThreadResolution.fromWire(rawResolved));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(Wire.string(rawTitle, "ConversationThreadState.title"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "owner", owner);
        Wire.put(object, "resolved", resolved);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadState that)) return false;
        return Objects.equals(owner, that.owner) && Objects.equals(resolved, that.resolved) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(owner, resolved, title); }

    @Override
    public String toString() { return "ConversationThreadState" + toWire(); }

    public static final class Builder {
        private Field<String> owner = Field.omitted();
        private Field<ConversationThreadResolution> resolved = Field.omitted();
        private Field<String> title = Field.omitted();

        public Builder owner(String value) {
            this.owner = Field.of(value);
            return this;
        }
        public Builder resolved(ConversationThreadResolution value) {
            this.resolved = Field.of(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.of(value);
            return this;
        }
        public ConversationThreadState build() { return new ConversationThreadState(this); }
    }
}
