// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SurfaceResult implements WireValue {
    private final Field<String> paneId;
    private final Field<String> screenId;
    private final UInt64 surface;
    private final Field<String> tabId;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;
    private final Field<String> terminalResourceId;
    private final Field<String> workspaceId;

    private SurfaceResult(Builder builder) {
        this.paneId = builder.paneId;
        this.screenId = builder.screenId;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.tabId = builder.tabId;
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
        this.terminalResourceId = builder.terminalResourceId;
        this.workspaceId = builder.workspaceId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> paneId() { return paneId; }
    public Field<String> screenId() { return screenId; }
    public UInt64 surface() { return surface; }
    public Field<String> tabId() { return tabId; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }
    public Field<String> terminalResourceId() { return terminalResourceId; }
    public Field<String> workspaceId() { return workspaceId; }

    public static SurfaceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SurfaceResult");
        Builder builder = builder();
        Object rawPaneId = Wire.optional(object, "pane_id");
        if (!Wire.isMissing(rawPaneId)) {
            builder.paneId(rawPaneId == null ? null : Wire.string(rawPaneId, "SurfaceResult.pane_id"));
        }
        Object rawScreenId = Wire.optional(object, "screen_id");
        if (!Wire.isMissing(rawScreenId)) {
            builder.screenId(Wire.string(rawScreenId, "SurfaceResult.screen_id"));
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
        Object rawTerminalResourceId = Wire.optional(object, "terminal_resource_id");
        if (!Wire.isMissing(rawTerminalResourceId)) {
            builder.terminalResourceId(Wire.string(rawTerminalResourceId, "SurfaceResult.terminal_resource_id"));
        }
        Object rawWorkspaceId = Wire.optional(object, "workspace_id");
        if (!Wire.isMissing(rawWorkspaceId)) {
            builder.workspaceId(Wire.string(rawWorkspaceId, "SurfaceResult.workspace_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane_id", paneId);
        Wire.put(object, "screen_id", screenId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "terminal_resource_id", terminalResourceId);
        Wire.put(object, "workspace_id", workspaceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SurfaceResult that)) return false;
        return Objects.equals(paneId, that.paneId) && Objects.equals(screenId, that.screenId) && Objects.equals(surface, that.surface) && Objects.equals(tabId, that.tabId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(terminalResourceId, that.terminalResourceId) && Objects.equals(workspaceId, that.workspaceId);
    }

    @Override
    public int hashCode() { return Objects.hash(paneId, screenId, surface, tabId, terminalId, terminalIncarnation, terminalResourceId, workspaceId); }

    @Override
    public String toString() { return "SurfaceResult" + toWire(); }

    public static final class Builder {
        private Field<String> paneId = Field.omitted();
        private Field<String> screenId = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> tabId = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();
        private Field<String> terminalResourceId = Field.omitted();
        private Field<String> workspaceId = Field.omitted();

        public Builder paneId(String value) {
            this.paneId = Field.ofNullable(value);
            return this;
        }
        public Builder screenId(String value) {
            this.screenId = Field.of(value);
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
        public Builder terminalResourceId(String value) {
            this.terminalResourceId = Field.of(value);
            return this;
        }
        public Builder workspaceId(String value) {
            this.workspaceId = Field.of(value);
            return this;
        }
        public SurfaceResult build() { return new SurfaceResult(this); }
    }
}
