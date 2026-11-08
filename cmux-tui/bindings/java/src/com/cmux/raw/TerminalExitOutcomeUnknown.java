// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalExitOutcomeUnknown implements WireValue, TerminalExitOutcome {
    private final String reason;

    private TerminalExitOutcomeUnknown(Builder builder) {
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return "unknown"; }
    public String reason() { return reason; }

    public static TerminalExitOutcomeUnknown fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalExitOutcomeUnknown");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "unknown", "TerminalExitOutcomeUnknown.kind");
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "TerminalExitOutcomeUnknown.reason"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", "unknown");
        Wire.put(object, "reason", reason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalExitOutcomeUnknown that)) return false;
        return Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(reason); }

    @Override
    public String toString() { return "TerminalExitOutcomeUnknown" + toWire(); }

    public static final class Builder {
        private String reason;
        private boolean reasonSet;

        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public TerminalExitOutcomeUnknown build() { return new TerminalExitOutcomeUnknown(this); }
    }
}
