// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-command-history request. Protocol v12; authority: local-admin. */
public final class SetTerminalCommandHistoryRequest implements WireValue {
    private final boolean enabled;
    private final Field<Long> retentionDays;

    private SetTerminalCommandHistoryRequest(Builder builder) {
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        this.retentionDays = builder.retentionDays;
    }

    public static Builder builder() { return new Builder(); }

    public boolean enabled() { return enabled; }
    public Field<Long> retentionDays() { return retentionDays; }

    public static SetTerminalCommandHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalCommandHistoryRequest");
        Builder builder = builder();
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "SetTerminalCommandHistoryRequest.enabled"));
        Object rawRetentionDays = Wire.optional(object, "retention_days");
        if (!Wire.isMissing(rawRetentionDays)) {
            builder.retentionDays(rawRetentionDays == null ? null : Wire.uint32(rawRetentionDays, "SetTerminalCommandHistoryRequest.retention_days"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "retention_days", retentionDays);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalCommandHistoryRequest that)) return false;
        return Objects.equals(enabled, that.enabled) && Objects.equals(retentionDays, that.retentionDays);
    }

    @Override
    public int hashCode() { return Objects.hash(enabled, retentionDays); }

    @Override
    public String toString() { return "SetTerminalCommandHistoryRequest" + toWire(); }

    public static final class Builder {
        private Boolean enabled;
        private boolean enabledSet;
        private Field<Long> retentionDays = Field.omitted();

        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder retentionDays(Long value) {
            this.retentionDays = Field.ofNullable(value);
            return this;
        }
        public SetTerminalCommandHistoryRequest build() { return new SetTerminalCommandHistoryRequest(this); }
    }
}
