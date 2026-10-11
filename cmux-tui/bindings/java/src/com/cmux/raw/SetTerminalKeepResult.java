// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetTerminalKeepResult implements WireValue {
    private final boolean keep;
    private final String terminalId;
    private final Field<String> terminalResourceId;

    private SetTerminalKeepResult(Builder builder) {
        if (!builder.keepSet) throw new IllegalArgumentException("keep is required");
        this.keep = builder.keep;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        this.terminalResourceId = builder.terminalResourceId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean keep() { return keep; }
    public String terminalId() { return terminalId; }
    public Field<String> terminalResourceId() { return terminalResourceId; }

    public static SetTerminalKeepResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalKeepResult");
        Builder builder = builder();
        Object rawKeep = Wire.required(object, "keep");
        builder.keep(Wire.bool(rawKeep, "SetTerminalKeepResult.keep"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "SetTerminalKeepResult.terminal_id"));
        Object rawTerminalResourceId = Wire.optional(object, "terminal_resource_id");
        if (!Wire.isMissing(rawTerminalResourceId)) {
            builder.terminalResourceId(rawTerminalResourceId == null ? null : Wire.string(rawTerminalResourceId, "SetTerminalKeepResult.terminal_resource_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "keep", keep);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_resource_id", terminalResourceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalKeepResult that)) return false;
        return Objects.equals(keep, that.keep) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalResourceId, that.terminalResourceId);
    }

    @Override
    public int hashCode() { return Objects.hash(keep, terminalId, terminalResourceId); }

    @Override
    public String toString() { return "SetTerminalKeepResult" + toWire(); }

    public static final class Builder {
        private Boolean keep;
        private boolean keepSet;
        private String terminalId;
        private boolean terminalIdSet;
        private Field<String> terminalResourceId = Field.omitted();

        public Builder keep(boolean value) {
            this.keep = value;
            this.keepSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalResourceId(String value) {
            this.terminalResourceId = Field.ofNullable(value);
            return this;
        }
        public SetTerminalKeepResult build() { return new SetTerminalKeepResult(this); }
    }
}
