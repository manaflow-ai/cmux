// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationThreadResolution implements WireValue {
    private final String at;
    private final String by;
    private final UInt64 seq;

    private ConversationThreadResolution(Builder builder) {
        if (!builder.atSet) throw new IllegalArgumentException("at is required");
        this.at = Wire.nonNull(builder.at, "at");
        if (!builder.bySet) throw new IllegalArgumentException("by is required");
        this.by = Wire.nonNull(builder.by, "by");
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
    }

    public static Builder builder() { return new Builder(); }

    public String at() { return at; }
    public String by() { return by; }
    public UInt64 seq() { return seq; }

    public static ConversationThreadResolution fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationThreadResolution");
        Builder builder = builder();
        Object rawAt = Wire.required(object, "at");
        builder.at(Wire.string(rawAt, "ConversationThreadResolution.at"));
        Object rawBy = Wire.required(object, "by");
        builder.by(Wire.string(rawBy, "ConversationThreadResolution.by"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "ConversationThreadResolution.seq"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "at", at);
        Wire.put(object, "by", by);
        Wire.put(object, "seq", seq);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationThreadResolution that)) return false;
        return Objects.equals(at, that.at) && Objects.equals(by, that.by) && Objects.equals(seq, that.seq);
    }

    @Override
    public int hashCode() { return Objects.hash(at, by, seq); }

    @Override
    public String toString() { return "ConversationThreadResolution" + toWire(); }

    public static final class Builder {
        private String at;
        private boolean atSet;
        private String by;
        private boolean bySet;
        private UInt64 seq;
        private boolean seqSet;

        public Builder at(String value) {
            this.at = value;
            this.atSet = true;
            return this;
        }
        public Builder by(String value) {
            this.by = value;
            this.bySet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public ConversationThreadResolution build() { return new ConversationThreadResolution(this); }
    }
}
