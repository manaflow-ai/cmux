// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable mint-terminal-renderer-by-terminal request. Protocol v11; authority: frontend. */
public final class MintTerminalRendererByTerminalRequest implements WireValue {
    private final String terminal;
    private final Field<UInt64> ttlMs;

    private MintTerminalRendererByTerminalRequest(Builder builder) {
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = Wire.nonNull(builder.terminal, "terminal");
        this.ttlMs = builder.ttlMs;
    }

    public static Builder builder() { return new Builder(); }

    public String terminal() { return terminal; }
    public Field<UInt64> ttlMs() { return ttlMs; }

    public static MintTerminalRendererByTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MintTerminalRendererByTerminalRequest");
        Builder builder = builder();
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(Wire.string(rawTerminal, "MintTerminalRendererByTerminalRequest.terminal"));
        Object rawTtlMs = Wire.optional(object, "ttl_ms");
        if (!Wire.isMissing(rawTtlMs)) {
            builder.ttlMs(Wire.uint64(rawTtlMs, "MintTerminalRendererByTerminalRequest.ttl_ms"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "terminal", terminal);
        Wire.put(object, "ttl_ms", ttlMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MintTerminalRendererByTerminalRequest that)) return false;
        return Objects.equals(terminal, that.terminal) && Objects.equals(ttlMs, that.ttlMs);
    }

    @Override
    public int hashCode() { return Objects.hash(terminal, ttlMs); }

    @Override
    public String toString() { return "MintTerminalRendererByTerminalRequest" + toWire(); }

    public static final class Builder {
        private String terminal;
        private boolean terminalSet;
        private Field<UInt64> ttlMs = Field.omitted();

        public Builder terminal(String value) {
            this.terminal = value;
            this.terminalSet = true;
            return this;
        }
        public Builder ttlMs(UInt64 value) {
            this.ttlMs = Field.of(value);
            return this;
        }
        public MintTerminalRendererByTerminalRequest build() { return new MintTerminalRendererByTerminalRequest(this); }
    }
}
