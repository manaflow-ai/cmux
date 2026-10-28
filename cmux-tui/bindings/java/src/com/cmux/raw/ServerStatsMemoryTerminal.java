// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemoryTerminal implements WireValue {
    private final UInt64 bytes;
    private final UInt64 scrollbackRows;
    private final String state;
    private final UInt64 surface;
    private final String terminalId;

    private ServerStatsMemoryTerminal(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.scrollbackRowsSet) throw new IllegalArgumentException("scrollback_rows is required");
        this.scrollbackRows = builder.scrollbackRows;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = builder.terminalId;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public UInt64 scrollbackRows() { return scrollbackRows; }
    public String state() { return state; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }

    public static ServerStatsMemoryTerminal fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemoryTerminal");
        Builder builder = builder();
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsMemoryTerminal.bytes"));
        Object rawScrollbackRows = Wire.required(object, "scrollback_rows");
        builder.scrollbackRows(rawScrollbackRows == null ? null : Wire.uint64(rawScrollbackRows, "ServerStatsMemoryTerminal.scrollback_rows"));
        Object rawState = Wire.required(object, "state");
        builder.state(Wire.string(rawState, "ServerStatsMemoryTerminal.state"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ServerStatsMemoryTerminal.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "ServerStatsMemoryTerminal.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "scrollback_rows", scrollbackRows);
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemoryTerminal that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(scrollbackRows, that.scrollbackRows) && Objects.equals(state, that.state) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, scrollbackRows, state, surface, terminalId); }

    @Override
    public String toString() { return "ServerStatsMemoryTerminal" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 scrollbackRows;
        private boolean scrollbackRowsSet;
        private String state;
        private boolean stateSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder scrollbackRows(UInt64 value) {
            this.scrollbackRows = value;
            this.scrollbackRowsSet = true;
            return this;
        }
        public Builder state(String value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public ServerStatsMemoryTerminal build() { return new ServerStatsMemoryTerminal(this); }
    }
}
