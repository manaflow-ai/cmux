// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-run request. Protocol v12; authority: local-admin. */
public final class ConversationRunRequest implements WireValue {
    private final Field<UInt64> afterRev;
    private final String conversation;
    private final Field<Long> limit;
    private final String run;

    private ConversationRunRequest(Builder builder) {
        this.afterRev = builder.afterRev;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        this.limit = builder.limit;
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = Wire.nonNull(builder.run, "run");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterRev() { return afterRev; }
    public String conversation() { return conversation; }
    public Field<Long> limit() { return limit; }
    public String run() { return run; }

    public static ConversationRunRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationRunRequest");
        Builder builder = builder();
        Object rawAfterRev = Wire.optional(object, "after_rev");
        if (!Wire.isMissing(rawAfterRev)) {
            builder.afterRev(Wire.uint64(rawAfterRev, "ConversationRunRequest.after_rev"));
        }
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationRunRequest.conversation"));
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "ConversationRunRequest.limit"));
        }
        Object rawRun = Wire.required(object, "run");
        builder.run(Wire.string(rawRun, "ConversationRunRequest.run"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_rev", afterRev);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "limit", limit);
        Wire.put(object, "run", run);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationRunRequest that)) return false;
        return Objects.equals(afterRev, that.afterRev) && Objects.equals(conversation, that.conversation) && Objects.equals(limit, that.limit) && Objects.equals(run, that.run);
    }

    @Override
    public int hashCode() { return Objects.hash(afterRev, conversation, limit, run); }

    @Override
    public String toString() { return "ConversationRunRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterRev = Field.omitted();
        private String conversation;
        private boolean conversationSet;
        private Field<Long> limit = Field.omitted();
        private String run;
        private boolean runSet;

        public Builder afterRev(UInt64 value) {
            this.afterRev = Field.of(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public Builder run(String value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public ConversationRunRequest build() { return new ConversationRunRequest(this); }
    }
}
