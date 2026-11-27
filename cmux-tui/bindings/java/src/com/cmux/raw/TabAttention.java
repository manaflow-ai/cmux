// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TabAttention implements WireValue {
    /** When it was marked, in Unix milliseconds. */
    private final UInt64 atMs;
    /** Why the tab needs the person. */
    private final String reason;

    private TabAttention(Builder builder) {
        if (!builder.atMsSet) throw new IllegalArgumentException("at_ms is required");
        this.atMs = Wire.nonNull(builder.atMs, "at_ms");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 atMs() { return atMs; }
    public String reason() { return reason; }

    public static TabAttention fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabAttention");
        Builder builder = builder();
        Object rawAtMs = Wire.required(object, "at_ms");
        builder.atMs(Wire.uint64(rawAtMs, "TabAttention.at_ms"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "TabAttention.reason"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "at_ms", atMs);
        Wire.put(object, "reason", reason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabAttention that)) return false;
        return Objects.equals(atMs, that.atMs) && Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(atMs, reason); }

    @Override
    public String toString() { return "TabAttention" + toWire(); }

    public static final class Builder {
        private UInt64 atMs;
        private boolean atMsSet;
        private String reason;
        private boolean reasonSet;

        public Builder atMs(UInt64 value) {
            this.atMs = value;
            this.atMsSet = true;
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public TabAttention build() { return new TabAttention(this); }
    }
}
