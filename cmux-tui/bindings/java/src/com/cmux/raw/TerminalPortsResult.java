// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalPortsResult implements WireValue {
    /** Ports the text names that refused the connect. */
    private final List<Integer> closed;
    private final List<TerminalPortsListener> listeners;
    private final UInt64 surface;

    private TerminalPortsResult(Builder builder) {
        if (!builder.closedSet) throw new IllegalArgumentException("closed is required");
        this.closed = List.copyOf(Wire.nonNull(builder.closed, "closed"));
        if (!builder.listenersSet) throw new IllegalArgumentException("listeners is required");
        this.listeners = List.copyOf(Wire.nonNull(builder.listeners, "listeners"));
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public List<Integer> closed() { return closed; }
    public List<TerminalPortsListener> listeners() { return listeners; }
    public UInt64 surface() { return surface; }

    public static TerminalPortsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalPortsResult");
        Builder builder = builder();
        Object rawClosed = Wire.required(object, "closed");
        builder.closed(Wire.array(rawClosed, "TerminalPortsResult.closed", item -> Wire.uint16(item, "TerminalPortsResult.closed item")));
        Object rawListeners = Wire.required(object, "listeners");
        builder.listeners(Wire.array(rawListeners, "TerminalPortsResult.listeners", item -> TerminalPortsListener.fromWire(item)));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalPortsResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "closed", closed);
        Wire.put(object, "listeners", listeners);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalPortsResult that)) return false;
        return Objects.equals(closed, that.closed) && Objects.equals(listeners, that.listeners) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(closed, listeners, surface); }

    @Override
    public String toString() { return "TerminalPortsResult" + toWire(); }

    public static final class Builder {
        private List<Integer> closed;
        private boolean closedSet;
        private List<TerminalPortsListener> listeners;
        private boolean listenersSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder closed(List<Integer> value) {
            this.closed = value;
            this.closedSet = true;
            return this;
        }
        public Builder listeners(List<TerminalPortsListener> value) {
            this.listeners = value;
            this.listenersSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public TerminalPortsResult build() { return new TerminalPortsResult(this); }
    }
}
