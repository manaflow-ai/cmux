// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable resolve-terminal request. Protocol v9; authority: control. */
public final class ResolveTerminalRequest implements WireValue {
    private final String terminalId;

    private ResolveTerminalRequest(Builder builder) {
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String terminalId() { return terminalId; }

    public static ResolveTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResolveTerminalRequest");
        Builder builder = builder();
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "ResolveTerminalRequest.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResolveTerminalRequest that)) return false;
        return Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(terminalId); }

    @Override
    public String toString() { return "ResolveTerminalRequest" + toWire(); }

    public static final class Builder {
        private String terminalId;
        private boolean terminalIdSet;

        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public ResolveTerminalRequest build() { return new ResolveTerminalRequest(this); }
    }
}
