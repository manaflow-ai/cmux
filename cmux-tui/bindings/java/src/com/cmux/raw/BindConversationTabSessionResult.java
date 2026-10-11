// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BindConversationTabSessionResult implements WireValue {
    private final ConversationTabRecord conversation;
    private final boolean replayed;
    private final UInt64 surface;

    private BindConversationTabSessionResult(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public ConversationTabRecord conversation() { return conversation; }
    public boolean replayed() { return replayed; }
    public UInt64 surface() { return surface; }

    public static BindConversationTabSessionResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BindConversationTabSessionResult");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationTabRecord.fromWire(rawConversation));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "BindConversationTabSessionResult.replayed"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BindConversationTabSessionResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BindConversationTabSessionResult that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(replayed, that.replayed) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, replayed, surface); }

    @Override
    public String toString() { return "BindConversationTabSessionResult" + toWire(); }

    public static final class Builder {
        private ConversationTabRecord conversation;
        private boolean conversationSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder conversation(ConversationTabRecord value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public BindConversationTabSessionResult build() { return new BindConversationTabSessionResult(this); }
    }
}
