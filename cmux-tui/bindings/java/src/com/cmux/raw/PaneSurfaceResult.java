// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PaneSurfaceResult implements WireValue {
    private final Field<String> paneId;
    private final Field<Boolean> replayed;
    private final UInt64 surface;
    private final Field<String> tabId;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;

    private PaneSurfaceResult(Builder builder) {
        this.paneId = builder.paneId;
        this.replayed = builder.replayed;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.tabId = builder.tabId;
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> paneId() { return paneId; }
    public Field<Boolean> replayed() { return replayed; }
    public UInt64 surface() { return surface; }
    public Field<String> tabId() { return tabId; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }

    public static PaneSurfaceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PaneSurfaceResult");
        Builder builder = builder();
        Object rawPaneId = Wire.optional(object, "pane_id");
        if (!Wire.isMissing(rawPaneId)) {
            builder.paneId(rawPaneId == null ? null : Wire.string(rawPaneId, "PaneSurfaceResult.pane_id"));
        }
        Object rawReplayed = Wire.optional(object, "replayed");
        if (!Wire.isMissing(rawReplayed)) {
            builder.replayed(rawReplayed == null ? null : Wire.bool(rawReplayed, "PaneSurfaceResult.replayed"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "PaneSurfaceResult.surface"));
        Object rawTabId = Wire.optional(object, "tab_id");
        if (!Wire.isMissing(rawTabId)) {
            builder.tabId(rawTabId == null ? null : Wire.string(rawTabId, "PaneSurfaceResult.tab_id"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "PaneSurfaceResult.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "PaneSurfaceResult.terminal_incarnation"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane_id", paneId);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PaneSurfaceResult that)) return false;
        return Objects.equals(paneId, that.paneId) && Objects.equals(replayed, that.replayed) && Objects.equals(surface, that.surface) && Objects.equals(tabId, that.tabId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation);
    }

    @Override
    public int hashCode() { return Objects.hash(paneId, replayed, surface, tabId, terminalId, terminalIncarnation); }

    @Override
    public String toString() { return "PaneSurfaceResult" + toWire(); }

    public static final class Builder {
        private Field<String> paneId = Field.omitted();
        private Field<Boolean> replayed = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> tabId = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();

        public Builder paneId(String value) {
            this.paneId = Field.ofNullable(value);
            return this;
        }
        public Builder replayed(Boolean value) {
            this.replayed = Field.ofNullable(value);
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
        public PaneSurfaceResult build() { return new PaneSurfaceResult(this); }
    }
}
