// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReportClientAttentionResult implements WireValue {
    /** The report came less than 250 ms after this connection's previous one; it is stored anyway (latest wins). */
    private final boolean coalesced;

    private ReportClientAttentionResult(Builder builder) {
        if (!builder.coalescedSet) throw new IllegalArgumentException("coalesced is required");
        this.coalesced = builder.coalesced;
    }

    public static Builder builder() { return new Builder(); }

    public boolean coalesced() { return coalesced; }

    public static ReportClientAttentionResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportClientAttentionResult");
        Builder builder = builder();
        Object rawCoalesced = Wire.required(object, "coalesced");
        builder.coalesced(Wire.bool(rawCoalesced, "ReportClientAttentionResult.coalesced"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "coalesced", coalesced);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportClientAttentionResult that)) return false;
        return Objects.equals(coalesced, that.coalesced);
    }

    @Override
    public int hashCode() { return Objects.hash(coalesced); }

    @Override
    public String toString() { return "ReportClientAttentionResult" + toWire(); }

    public static final class Builder {
        private Boolean coalesced;
        private boolean coalescedSet;

        public Builder coalesced(boolean value) {
            this.coalesced = value;
            this.coalescedSet = true;
            return this;
        }
        public ReportClientAttentionResult build() { return new ReportClientAttentionResult(this); }
    }
}
