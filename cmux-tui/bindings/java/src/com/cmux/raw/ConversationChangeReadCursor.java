// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationChangeReadCursor implements WireValue, ConversationChange {
    private final String participant;
    private final UInt64 seq;

    private ConversationChangeReadCursor(Builder builder) {
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return "read-cursor"; }
    public String participant() { return participant; }
    public UInt64 seq() { return seq; }

    public static ConversationChangeReadCursor fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChangeReadCursor");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "read-cursor", "ConversationChangeReadCursor.kind");
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "ConversationChangeReadCursor.participant"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ConversationChangeReadCursor.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", "read-cursor");
        Wire.put(object, "participant", participant);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationChangeReadCursor that)) return false;
        return Objects.equals(participant, that.participant) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(participant, seq); }

    @Override
    public String toString() { return "ConversationChangeReadCursor" + toWire(); }

    public static final class Builder {
        private String participant;
        private boolean participantSet;
        private UInt64 seq;
        private boolean seqSet;

        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public ConversationChangeReadCursor build() { return new ConversationChangeReadCursor(this); }
    }
}
