// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SurfaceResult implements WireValue {
    private final Field<UInt64> pane;
    private final Field<UInt64> screen;
    private final UInt64 surface;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;
    private final Field<UInt64> workspace;

    private SurfaceResult(Builder builder) {
        this.pane = builder.pane;
        this.screen = builder.screen;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> pane() { return pane; }
    public Field<UInt64> screen() { return screen; }
    public UInt64 surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }
    public Field<UInt64> workspace() { return workspace; }

    public static SurfaceResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SurfaceResult");
        Builder builder = builder();
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(Wire.uint64(rawPane, "SurfaceResult.pane"));
        }
        Object rawScreen = Wire.optional(object, "screen");
        if (!Wire.isMissing(rawScreen)) {
            builder.screen(Wire.uint64(rawScreen, "SurfaceResult.screen"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SurfaceResult.surface"));
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SurfaceResult.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "SurfaceResult.terminal_incarnation"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(Wire.uint64(rawWorkspace, "SurfaceResult.workspace"));
        }
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
        if (!(other instanceof SurfaceResult that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(screen, that.screen) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, screen, surface, terminalId, terminalIncarnation, workspace); }

    @Override
    public String toString() { return "SurfaceResult" + toWire(); }

    public static final class Builder {
        private Field<UInt64> pane = Field.omitted();
        private Field<UInt64> screen = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder pane(UInt64 value) {
            this.pane = Field.of(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
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
        public Builder workspace(UInt64 value) {
            this.workspace = Field.of(value);
            return this;
        }
        public SurfaceResult build() { return new SurfaceResult(this); }
    }
}
