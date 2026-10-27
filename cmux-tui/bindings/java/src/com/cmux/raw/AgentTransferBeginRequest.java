// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-transfer-begin request. Protocol v12; authority: local-admin. */
public final class AgentTransferBeginRequest implements WireValue {
    private final Field<Boolean> askFirst;
    private final Field<Boolean> interrupt;
    private final UInt64 surface;

    private AgentTransferBeginRequest(Builder builder) {
        this.askFirst = builder.askFirst;
        this.interrupt = builder.interrupt;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> askFirst() { return askFirst; }
    public Field<Boolean> interrupt() { return interrupt; }
    public UInt64 surface() { return surface; }

    public static AgentTransferBeginRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentTransferBeginRequest");
        Builder builder = builder();
        Object rawAskFirst = Wire.optional(object, "ask_first");
        if (!Wire.isMissing(rawAskFirst)) {
            builder.askFirst(Wire.bool(rawAskFirst, "AgentTransferBeginRequest.ask_first"));
        }
        Object rawInterrupt = Wire.optional(object, "interrupt");
        if (!Wire.isMissing(rawInterrupt)) {
            builder.interrupt(Wire.bool(rawInterrupt, "AgentTransferBeginRequest.interrupt"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentTransferBeginRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ask_first", askFirst);
        Wire.put(object, "interrupt", interrupt);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentTransferBeginRequest that)) return false;
        return Objects.equals(askFirst, that.askFirst) && Objects.equals(interrupt, that.interrupt) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(askFirst, interrupt, surface); }

    @Override
    public String toString() { return "AgentTransferBeginRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> askFirst = Field.omitted();
        private Field<Boolean> interrupt = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder askFirst(Boolean value) {
            this.askFirst = Field.of(value);
            return this;
        }
        public Builder interrupt(Boolean value) {
            this.interrupt = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentTransferBeginRequest build() { return new AgentTransferBeginRequest(this); }
    }
}
