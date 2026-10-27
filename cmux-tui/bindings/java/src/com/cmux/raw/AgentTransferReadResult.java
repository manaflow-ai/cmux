// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentTransferReadResult implements WireValue {
    private final Bytes data;
    private final boolean eof;
    private final UInt64 next;

    private AgentTransferReadResult(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.eofSet) throw new IllegalArgumentException("eof is required");
        this.eof = builder.eof;
        if (!builder.nextSet) throw new IllegalArgumentException("next is required");
        this.next = Wire.nonNull(builder.next, "next");
    }

    public static Builder builder() { return new Builder(); }

    public Bytes data() { return data; }
    public boolean eof() { return eof; }
    public UInt64 next() { return next; }

    public static AgentTransferReadResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferReadResult");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "AgentTransferReadResult.data"));
        Object rawEof = Wire.required(object, "eof");
        builder.eof(Wire.bool(rawEof, "AgentTransferReadResult.eof"));
        Object rawNext = Wire.required(object, "next");
        builder.next(Wire.uint64(rawNext, "AgentTransferReadResult.next"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "eof", eof);
        Wire.put(object, "next", next);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferReadResult that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(eof, that.eof) && Objects.equals(next, that.next);
    }

    @Override
    public int hashCode() { return Objects.hash(data, eof, next); }

    @Override
    public String toString() { return "AgentTransferReadResult" + toWire(); }

    public static final class Builder {
        private Bytes data;
        private boolean dataSet;
        private Boolean eof;
        private boolean eofSet;
        private UInt64 next;
        private boolean nextSet;

        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder eof(boolean value) {
            this.eof = value;
            this.eofSet = true;
            return this;
        }
        public Builder next(UInt64 value) {
            this.next = value;
            this.nextSet = true;
            return this;
        }
        public AgentTransferReadResult build() { return new AgentTransferReadResult(this); }
    }
}
