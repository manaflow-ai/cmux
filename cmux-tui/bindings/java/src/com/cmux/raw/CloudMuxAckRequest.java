// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-mux-ack request. Protocol v12; authority: local-admin. */
public final class CloudMuxAckRequest implements WireValue {
    private final String conversation;
    private final UInt64 seq;

    private CloudMuxAckRequest(Builder builder) {
        if (!builder.conversationSet) throw new IllegalArgumentException("conversation is required");
        this.conversation = Wire.nonNull(builder.conversation, "conversation");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public String conversation() { return conversation; }
    public UInt64 seq() { return seq; }

    public static CloudMuxAckRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudMuxAckRequest");
        Builder builder = builder();
        Object rawConversation = Wire.required(object, "conversation");
        builder.conversation(Wire.string(rawConversation, "CloudMuxAckRequest.conversation"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "CloudMuxAckRequest.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudMuxAckRequest that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, seq); }

    @Override
    public String toString() { return "CloudMuxAckRequest" + toWire(); }

    public static final class Builder {
        private String conversation;
        private boolean conversationSet;
        private UInt64 seq;
        private boolean seqSet;

        public Builder conversation(String value) {
            this.conversation = value;
            this.conversationSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public CloudMuxAckRequest build() { return new CloudMuxAckRequest(this); }
    }
}
