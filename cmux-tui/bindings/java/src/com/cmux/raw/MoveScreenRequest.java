// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-screen request. Protocol v12; authority: control. */
public final class MoveScreenRequest implements WireValue {
    private final Field<UInt64> index;
    private final Field<Boolean> newWorkspace;
    private final UInt64 screen;
    private final Field<UInt64> workspace;

    private MoveScreenRequest(Builder builder) {
        this.index = builder.index;
        this.newWorkspace = builder.newWorkspace;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> index() { return index; }
    public Field<Boolean> newWorkspace() { return newWorkspace; }
    public UInt64 screen() { return screen; }
    public Field<UInt64> workspace() { return workspace; }

    public static MoveScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveScreenRequest");
        Builder builder = builder();
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "MoveScreenRequest.index"));
        }
        Object rawNewWorkspace = Wire.optional(object, "new_workspace");
        if (!Wire.isMissing(rawNewWorkspace)) {
            builder.newWorkspace(Wire.bool(rawNewWorkspace, "MoveScreenRequest.new_workspace"));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "MoveScreenRequest.screen"));
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "MoveScreenRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "index", index);
        Wire.put(object, "new_workspace", newWorkspace);
        Wire.put(object, "screen", screen);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveScreenRequest that)) return false;
        return Objects.equals(index, that.index) && Objects.equals(newWorkspace, that.newWorkspace) && Objects.equals(screen, that.screen) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(index, newWorkspace, screen, workspace); }

    @Override
    public String toString() { return "MoveScreenRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> index = Field.omitted();
        private Field<Boolean> newWorkspace = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;
        private Field<UInt64> workspace = Field.omitted();

        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder newWorkspace(Boolean value) {
            this.newWorkspace = Field.of(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public MoveScreenRequest build() { return new MoveScreenRequest(this); }
    }
}
