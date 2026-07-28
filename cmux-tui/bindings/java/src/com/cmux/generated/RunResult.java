// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.generated;


import com.cmux.Bytes;
import com.cmux.Field;
import com.cmux.UInt64;
import com.cmux.Wire;
import com.cmux.WireEnum;
import com.cmux.WireValue;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RunResult implements WireValue {
    private final UInt64 pane;
    private final UInt64 screen;
    private final UInt64 surface;
    private final String terminalId;
    private final String terminalIncarnation;
    private final UInt64 workspace;

    private RunResult(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = builder.terminalId;
        if (!builder.terminalIncarnationSet) throw new IllegalArgumentException("terminal_incarnation is required");
        this.terminalIncarnation = builder.terminalIncarnation;
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public UInt64 screen() { return screen; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public UInt64 workspace() { return workspace; }

    public static RunResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RunResult");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "RunResult.pane"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "RunResult.screen"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "RunResult.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "RunResult.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "RunResult.terminal_incarnation"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "RunResult.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "screen", screen);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RunResult that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(screen, that.screen) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, screen, surface, terminalId, terminalIncarnation, workspace); }

    @Override
    public String toString() { return "RunResult" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 screen;
        private boolean screenSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String terminalIncarnation;
        private boolean terminalIncarnationSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
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
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = value;
            this.terminalIncarnationSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public RunResult build() { return new RunResult(this); }
    }
}
