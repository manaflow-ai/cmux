// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class ConversationReactionKind implements WireValue {
    public enum Kind { CONVERSATION_TAPBACK_REACTION, CONVERSATION_EMOJI_REACTION }
    private final Kind kind;
    private final Object value;
    private ConversationReactionKind(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static ConversationReactionKind ofConversationTapbackReaction(ConversationTapbackReaction value) {
        return new ConversationReactionKind(Kind.CONVERSATION_TAPBACK_REACTION, value);
    }
    public boolean isConversationTapbackReaction() { return kind == Kind.CONVERSATION_TAPBACK_REACTION; }
    public ConversationTapbackReaction conversationTapbackReaction() {
        if (!isConversationTapbackReaction()) throw new IllegalStateException("ConversationReactionKind contains " + kind);
        return (ConversationTapbackReaction) value;
    }

    public static ConversationReactionKind ofConversationEmojiReaction(ConversationEmojiReaction value) {
        return new ConversationReactionKind(Kind.CONVERSATION_EMOJI_REACTION, value);
    }
    public boolean isConversationEmojiReaction() { return kind == Kind.CONVERSATION_EMOJI_REACTION; }
    public ConversationEmojiReaction conversationEmojiReaction() {
        if (!isConversationEmojiReaction()) throw new IllegalStateException("ConversationReactionKind contains " + kind);
        return (ConversationEmojiReaction) value;
    }

    public static ConversationReactionKind fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofConversationTapbackReaction(ConversationTapbackReaction.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofConversationEmojiReaction(ConversationEmojiReaction.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no ConversationReactionKind variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof ConversationReactionKind that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "ConversationReactionKind[" + value + "]"; }
}
