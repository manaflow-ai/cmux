// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-terminal-keep request. Protocol v12; authority: control. */
public final class SetTerminalKeepRequest implements WireValue {
    private final boolean keep;
    private final Field<UInt64> surface;
    private final Field<String> terminalId;

    private SetTerminalKeepRequest(Builder builder) {
        if (!builder.keepSet) throw new IllegalArgumentException("keep is required");
        this.keep = builder.keep;
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public boolean keep() { return keep; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }

    public static SetTerminalKeepRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetTerminalKeepRequest");
        Builder builder = builder();
        Object rawKeep = Wire.required(object, "keep");
        builder.keep(Wire.bool(rawKeep, "SetTerminalKeepRequest.keep"));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SetTerminalKeepRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SetTerminalKeepRequest.terminal_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "keep", keep);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetTerminalKeepRequest that)) return false;
        return Objects.equals(keep, that.keep) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(keep, surface, terminalId); }

    @Override
    public String toString() { return "SetTerminalKeepRequest" + toWire(); }

    public static final class Builder {
        private Boolean keep;
        private boolean keepSet;
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();

        public Builder keep(boolean value) {
            this.keep = value;
            this.keepSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public SetTerminalKeepRequest build() { return new SetTerminalKeepRequest(this); }
    }
}
