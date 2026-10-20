// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalExitOutcomeExit implements WireValue, TerminalExitOutcome {
    private final int code;

    private TerminalExitOutcomeExit(Builder builder) {
        if (!builder.codeSet) throw new IllegalArgumentException("code is required");
        this.code = builder.code;
    }

    public static Builder builder() { return new Builder(); }

    public int code() { return code; }
    public String kind() { return "exit"; }

    public static TerminalExitOutcomeExit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalExitOutcomeExit");
        Builder builder = builder();
        Object rawCode = Wire.required(object, "code");
        builder.code(Wire.int32(rawCode, "TerminalExitOutcomeExit.code"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "exit", "TerminalExitOutcomeExit.kind");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "code", code);
        Wire.put(object, "kind", "exit");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalExitOutcomeExit that)) return false;
        return Objects.equals(code, that.code);
    }

    @Override
    public int hashCode() { return Objects.hash(code); }

    @Override
    public String toString() { return "TerminalExitOutcomeExit" + toWire(); }

    public static final class Builder {
        private Integer code;
        private boolean codeSet;

        public Builder code(int value) {
            this.code = value;
            this.codeSet = true;
            return this;
        }
        public TerminalExitOutcomeExit build() { return new TerminalExitOutcomeExit(this); }
    }
}
