// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionStartResult implements WireValue {
    private final ConversationTabRecord conversation;
    /** The new acpmux session, bound to the tab. */
    private final String session;
    private final UInt64 surface;

    private AgentSessionStartResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationTabRecord conversation() { return conversation; }
    public String session() { return session; }
    public UInt64 surface() { return surface; }

    public static AgentSessionStartResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionStartResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationTabRecord.fromWire(rawConversation));
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "AgentSessionStartResult.session"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionStartResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "session", session);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionStartResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(session, that.session) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, session, surface); }

    @Override
    public String toString() { return "AgentSessionStartResult" + toWire(); }

    public static final class Builder {
        private ConversationTabRecord conversation;
        private boolean conversationSet;
        private String session;
        private boolean sessionSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder conversation(ConversationTabRecord value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionStartResult build() { return new AgentSessionStartResult(this); }
    }
}
