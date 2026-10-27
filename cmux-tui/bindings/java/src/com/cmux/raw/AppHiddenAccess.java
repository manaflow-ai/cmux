// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppHiddenAccess implements WireValue {
    private final boolean automations;
    private final boolean cli;
    private final boolean mcp;

    private AppHiddenAccess(Builder builder) {
        if (!builder.automationsSet) throw new IllegalArgumentException("automations is required");
        this.automations = builder.automations;
        if (!builder.cliSet) throw new IllegalArgumentException("cli is required");
        this.cli = builder.cli;
        if (!builder.mcpSet) throw new IllegalArgumentException("mcp is required");
        this.mcp = builder.mcp;
    }

    public static Builder builder() { return new Builder(); }

    public boolean automations() { return automations; }
    public boolean cli() { return cli; }
    public boolean mcp() { return mcp; }

    public static AppHiddenAccess fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppHiddenAccess");
        Builder builder = builder();
        Object rawAutomations = Wire.required(object, "automations");
        builder.automations(Wire.bool(rawAutomations, "AppHiddenAccess.automations"));
        Object rawCli = Wire.required(object, "cli");
        builder.cli(Wire.bool(rawCli, "AppHiddenAccess.cli"));
        Object rawMcp = Wire.required(object, "mcp");
        builder.mcp(Wire.bool(rawMcp, "AppHiddenAccess.mcp"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "automations", automations);
        Wire.put(object, "cli", cli);
        Wire.put(object, "mcp", mcp);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppHiddenAccess that)) return false;
        return Objects.equals(automations, that.automations) && Objects.equals(cli, that.cli) && Objects.equals(mcp, that.mcp);
    }

    @Override
    public int hashCode() { return Objects.hash(automations, cli, mcp); }

    @Override
    public String toString() { return "AppHiddenAccess" + toWire(); }

    public static final class Builder {
        private Boolean automations;
        private boolean automationsSet;
        private Boolean cli;
        private boolean cliSet;
        private Boolean mcp;
        private boolean mcpSet;

        public Builder automations(boolean value) {
            this.automations = value;
            this.automationsSet = true;
            return this;
        }
        public Builder cli(boolean value) {
            this.cli = value;
            this.cliSet = true;
            return this;
        }
        public Builder mcp(boolean value) {
            this.mcp = value;
            this.mcpSet = true;
            return this;
        }
        public AppHiddenAccess build() { return new AppHiddenAccess(this); }
    }
}
