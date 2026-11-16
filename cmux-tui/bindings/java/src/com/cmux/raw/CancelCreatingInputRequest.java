// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cancel-creating-input request. Protocol v12; authority: control. */
public final class CancelCreatingInputRequest implements WireValue {
    private final String terminalId;

    private CancelCreatingInputRequest(Builder builder) {
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String terminalId() { return terminalId; }

    public static CancelCreatingInputRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CancelCreatingInputRequest");
        Builder builder = builder();
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "CancelCreatingInputRequest.terminal_id"));
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
        if (!(other instanceof CancelCreatingInputRequest that)) return false;
        return Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(terminalId); }

    @Override
    public String toString() { return "CancelCreatingInputRequest" + toWire(); }

    public static final class Builder {
        private String terminalId;
        private boolean terminalIdSet;

        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public CancelCreatingInputRequest build() { return new CancelCreatingInputRequest(this); }
    }
}
