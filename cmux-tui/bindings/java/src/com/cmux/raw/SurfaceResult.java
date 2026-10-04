// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SurfaceResult implements WireValue {
    private final Field<SurfaceLifecycle> lifecycle;
    private final UInt64 surface;
    private final Field<String> tabId;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;

    private SurfaceResult(Builder builder) {
        this.lifecycle = builder.lifecycle;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.tabId = builder.tabId;
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SurfaceLifecycle> lifecycle() { return lifecycle; }
    public UInt64 surface() { return surface; }
    public Field<String> tabId() { return tabId; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }

    public static SurfaceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SurfaceResult");
        Builder builder = builder();
        Object rawLifecycle = Wire.optional(object, "lifecycle");
        if (!Wire.isMissing(rawLifecycle)) {
            builder.lifecycle(SurfaceLifecycle.fromWire(rawLifecycle));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SurfaceResult.surface"));
        Object rawTabId = Wire.optional(object, "tab_id");
        if (!Wire.isMissing(rawTabId)) {
            builder.tabId(rawTabId == null ? null : Wire.string(rawTabId, "SurfaceResult.tab_id"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SurfaceResult.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "SurfaceResult.terminal_incarnation"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "lifecycle", lifecycle);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SurfaceResult that)) return false;
        return Objects.equals(lifecycle, that.lifecycle) && Objects.equals(surface, that.surface) && Objects.equals(tabId, that.tabId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation);
    }

    @Override
    public int hashCode() { return Objects.hash(lifecycle, surface, tabId, terminalId, terminalIncarnation); }

    @Override
    public String toString() { return "SurfaceResult" + toWire(); }

    public static final class Builder {
        private Field<SurfaceLifecycle> lifecycle = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> tabId = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();

        public Builder lifecycle(SurfaceLifecycle value) {
            this.lifecycle = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder tabId(String value) {
            this.tabId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = Field.ofNullable(value);
            return this;
        }
        public SurfaceResult build() { return new SurfaceResult(this); }
    }
}
