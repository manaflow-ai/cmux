// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NewConversationTabResult implements WireValue {
    private final String contentResourceId;
    private final ConversationTabRecord conversation;
    private final boolean replayed;
    private final UInt64 surface;
    private final String tabResourceId;

    private NewConversationTabResult(Builder builder) {
        if (!builder.contentResourceIdSet) throw new IllegalArgumentException("content_resource_id is required");
        this.contentResourceId = builder.contentResourceId;
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.tabResourceIdSet) throw new IllegalArgumentException("tab_resource_id is required");
        this.tabResourceId = builder.tabResourceId;
    }

    public static Builder builder() { return new Builder(); }

    public String contentResourceId() { return contentResourceId; }
    public ConversationTabRecord conversation() { return conversation; }
    public boolean replayed() { return replayed; }
    public UInt64 surface() { return surface; }
    public String tabResourceId() { return tabResourceId; }

    public static NewConversationTabResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewConversationTabResult");
        Builder builder = builder();
        Object rawContentResourceId = Wire.required(object, "content_resource_id");
        builder.contentResourceId(rawContentResourceId == null ? null : Wire.string(rawContentResourceId, "NewConversationTabResult.content_resource_id"));
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(ConversationTabRecord.fromWire(rawConversation));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "NewConversationTabResult.replayed"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "NewConversationTabResult.surface"));
        Object rawTabResourceId = Wire.required(object, "tab_resource_id");
        builder.tabResourceId(rawTabResourceId == null ? null : Wire.string(rawTabResourceId, "NewConversationTabResult.tab_resource_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "content_resource_id", contentResourceId);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_resource_id", tabResourceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewConversationTabResult that)) return false;
        return Objects.equals(contentResourceId, that.contentResourceId) && Objects.equals(conversation, that.conversation) && Objects.equals(replayed, that.replayed) && Objects.equals(surface, that.surface) && Objects.equals(tabResourceId, that.tabResourceId);
    }

    @Override
    public int hashCode() { return Objects.hash(contentResourceId, conversation, replayed, surface, tabResourceId); }

    @Override
    public String toString() { return "NewConversationTabResult" + toWire(); }

    public static final class Builder {
        private String contentResourceId;
        private boolean contentResourceIdSet;
        private ConversationTabRecord conversation;
        private boolean conversationSet;
        private Boolean replayed;
        private boolean replayedSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String tabResourceId;
        private boolean tabResourceIdSet;

        public Builder contentResourceId(String value) {
            this.contentResourceId = value;
            this.contentResourceIdSet = true;
            return this;
        }
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
        public Builder tabResourceId(String value) {
            this.tabResourceId = value;
            this.tabResourceIdSet = true;
            return this;
        }
        public NewConversationTabResult build() { return new NewConversationTabResult(this); }
    }
}
