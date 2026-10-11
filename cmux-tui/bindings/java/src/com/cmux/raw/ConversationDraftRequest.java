// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-draft request. Protocol v12; authority: local-admin. */
public final class ConversationDraftRequest implements WireValue {
    private final String conversation;
    private final boolean done;
    private final boolean fresh;
    private final Field<String> harness;
    private final String kind;
    private final UInt64 segment;
    private final UInt64 seq;
    private final String text;
    private final Field<Boolean> truncated;
    private final String turn;

    private ConversationDraftRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.doneSet) throw new IllegalArgumentException("done is required");
        this.done = builder.done;
        if (!builder.freshSet) throw new IllegalArgumentException("fresh is required");
        this.fresh = builder.fresh;
        this.harness = builder.harness;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.segmentSet) throw new IllegalArgumentException("segment is required");
        this.segment = Wire.nonNull(builder.segment, "segment");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
        this.truncated = builder.truncated;
        if (!builder.turnSet) throw new IllegalArgumentException("turn is required");
        this.turn = Wire.nonNull(builder.turn, "turn");
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public boolean done() { return done; }
    public boolean fresh() { return fresh; }
    public Field<String> harness() { return harness; }
    public String kind() { return kind; }
    public UInt64 segment() { return segment; }
    public UInt64 seq() { return seq; }
    public String text() { return text; }
    public Field<Boolean> truncated() { return truncated; }
    public String turn() { return turn; }

    public static ConversationDraftRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationDraftRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "ConversationDraftRequest.conversation"));
        Object rawDone = Wire.required(object, "done");
        builder.done(Wire.bool(rawDone, "ConversationDraftRequest.done"));
        Object rawFresh = Wire.required(object, "fresh");
        builder.fresh(Wire.bool(rawFresh, "ConversationDraftRequest.fresh"));
        Object rawHarness = Wire.optional(object, "harness");
        if (!Wire.isMissing(rawHarness)) {
            builder.harness(rawHarness == null ? null : Wire.string(rawHarness, "ConversationDraftRequest.harness"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ConversationDraftRequest.kind"));
        Object rawSegment = Wire.required(object, "segment");
        builder.segment(Wire.uint64(rawSegment, "ConversationDraftRequest.segment"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ConversationDraftRequest.seq"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "ConversationDraftRequest.text"));
        Object rawTruncated = Wire.optional(object, "truncated");
        if (!Wire.isMissing(rawTruncated)) {
            builder.truncated(rawTruncated == null ? null : Wire.bool(rawTruncated, "ConversationDraftRequest.truncated"));
        }
        Object rawTurn = Wire.required(object, "turn");
        builder.turn(Wire.string(rawTurn, "ConversationDraftRequest.turn"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "done", done);
        Wire.put(object, "fresh", fresh);
        Wire.put(object, "harness", harness);
        Wire.put(object, "kind", kind);
        Wire.put(object, "segment", segment);
        Wire.put(object, "seq", seq);
        Wire.put(object, "text", text);
        Wire.put(object, "truncated", truncated);
        Wire.put(object, "turn", turn);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationDraftRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(done, that.done) && Objects.equals(fresh, that.fresh) && Objects.equals(harness, that.harness) && Objects.equals(kind, that.kind) && Objects.equals(segment, that.segment) && Objects.equals(seq, that.seq) && Objects.equals(text, that.text) && Objects.equals(truncated, that.truncated) && Objects.equals(turn, that.turn);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, done, fresh, harness, kind, segment, seq, text, truncated, turn); }

    @Override
    public String toString() { return "ConversationDraftRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private Boolean done;
        private boolean doneSet;
        private Boolean fresh;
        private boolean freshSet;
        private Field<String> harness = Field.omitted();
        private String kind;
        private boolean kindSet;
        private UInt64 segment;
        private boolean segmentSet;
        private UInt64 seq;
        private boolean seqSet;
        private String text;
        private boolean textSet;
        private Field<Boolean> truncated = Field.omitted();
        private String turn;
        private boolean turnSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder done(boolean value) {
            this.done = value;
            this.doneSet = true;
            return this;
        }
        public Builder fresh(boolean value) {
            this.fresh = value;
            this.freshSet = true;
            return this;
        }
        public Builder harness(String value) {
            this.harness = Field.ofNullable(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder segment(UInt64 value) {
            this.segment = value;
            this.segmentSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public Builder truncated(Boolean value) {
            this.truncated = Field.ofNullable(value);
            return this;
        }
        public Builder turn(String value) {
            this.turn = value;
            this.turnSet = true;
            return this;
        }
        public ConversationDraftRequest build() { return new ConversationDraftRequest(this); }
    }
}
