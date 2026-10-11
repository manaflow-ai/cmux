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

    private SetTerminalCommandHistoryRequest(Builder builder) {
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
    }

    public static Builder builder() { return new Builder(); }

    public boolean enabled() { return enabled; }

    public static SetTerminalCommandHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalCommandHistoryRequest");
        Builder builder = builder();
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "SetTerminalCommandHistoryRequest.enabled"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "enabled", enabled);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalCommandHistoryRequest that)) return false;
        return Objects.equals(enabled, that.enabled);
    }

    @Override
    public int hashCode() { return Objects.hash(enabled); }

    @Override
    public String toString() { return "SetTerminalCommandHistoryRequest" + toWire(); }

    public static final class Builder {
        private Boolean enabled;
        private boolean enabledSet;

        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public SetTerminalCommandHistoryRequest build() { return new SetTerminalCommandHistoryRequest(this); }
    }
}
